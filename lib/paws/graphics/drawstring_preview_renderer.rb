# frozen_string_literal: true

require_relative "shade_pattern"

module PAWS
  module Graphics
    # Provisional renderer for PAWS drawstring reverse engineering.
    #
    # It intentionally renders only the currently understood geometry and
    # effects. PAW graphics use a 176-pixel high internal coordinate range; live
    # Spectrum screens may contain parser text below the picture. Normal
    # plot/line operations set pixels, INVERSE clears them, OVER toggles them,
    # and INVERSE+OVER is a bitmap-neutral cursor move. PAW still updates the
    # destination attribute cell for absolute moves.
    class DrawstringPreviewRenderer
      WIDTH = 256
      HEIGHT = 192
      GRAPHICS_HEIGHT = 176
      MAX_FILL_PIXELS = 16_384
      MAX_EDGE_FILL_PIXELS = 4_096
      GLYPHS = {
        0x4F => [
          "00000000",
          "00111100",
          "01000010",
          "01000010",
          "01000010",
          "01000010",
          "00111100",
          "00000000",
        ],
        0x7F => [
          "01111110",
          "11000011",
          "10011101",
          "10110001",
          "10110001",
          "00011101",
          "01000011",
          "01111110",
        ],
      }.freeze

      def initialize(render_family2_seeds: false, family2_mode: nil, pictures_by_id: nil, render_gosubs: true, allow_edge_fills: false, charsets: nil, charset_id: nil, udgs: nil, shade_patterns: nil, preserve_paper_on_pixel_attributes: false)
        @family2_mode = family2_mode || (render_family2_seeds ? :seeds : :none)
        @pictures_by_id = normalize_pictures_by_id(pictures_by_id)
        @render_gosubs = render_gosubs
        @allow_edge_fills = allow_edge_fills
        @charset_glyphs = normalize_charset_glyphs(charsets, charset_id)
        @udg_glyphs = normalize_udg_glyphs(udgs)
        @shade_patterns = normalize_shade_patterns(shade_patterns)
        @preserve_paper_on_pixel_attributes = preserve_paper_on_pixel_attributes
      end

      RenderResult = Struct.new(
        :pixels,
        :attributes,
        :commands_seen,
        :commands_rendered,
        :commands_skipped,
        :pixels_set,
        keyword_init: true,
      )

      def render(commands, initial_attribute: nil, screen_attribute: nil, base_pixels: nil, base_attributes: nil)
        pixels = base_pixels ? copy_pixels(base_pixels) : Array.new(HEIGHT) { Array.new(WIDTH, false) }
        current_attribute = normalize_attribute(initial_attribute)
        base_attribute = drawable_attribute(normalize_attribute(screen_attribute || initial_attribute))
        attributes = base_attributes ? copy_attributes(base_attributes) : Array.new(HEIGHT / 8) { Array.new(WIDTH / 8) { base_attribute.dup } }
        counters = Hash.new(0)
        @paper_attribute_path = []
        @paper_attribute_fill_attribute = nil
        @drawn_character_cells = {}

        render_commands(pixels, attributes, current_attribute, commands, counters, cursor: origin_point, gosub_stack: [], scale: 0)

        RenderResult.new(
          pixels: pixels,
          attributes: attributes,
          commands_seen: counters[:commands_seen],
          commands_rendered: counters[:commands_rendered],
          commands_skipped: counters[:commands_skipped],
          pixels_set: count_pixels(pixels),
        )
      end

      def to_pbm(render_result)
        lines = ["P1", "#{WIDTH} #{HEIGHT}"]
        render_result.pixels.each do |row|
          lines << row.map { |pixel| pixel ? "1" : "0" }.join(" ")
        end
        "#{lines.join("\n")}\n"
      end

      private

      attr_reader :family2_mode, :pictures_by_id, :charset_glyphs, :udg_glyphs, :shade_patterns

      def copy_pixels(pixels)
        pixels.map { |row| row.map { |pixel| pixel ? true : false } }
      end

      def copy_attributes(attributes)
        attributes.map { |row| row.map { |attribute| attribute.dup } }
      end

      def render_commands(pixels, attributes, current_attribute, commands, counters, cursor:, gosub_stack:, scale:)
        cursor = cursor.dup
        commands.each do |command|
          counters[:commands_seen] += 1

          case command["family"]
          when 0
            cursor = absolute_point(command) || cursor
            render_plot(pixels, attributes, current_attribute, command, counters, cursor)
          when 1
            from = command_delta?(command) ? cursor : (command["point_before"] || cursor)
            cursor = relative_point(command, cursor, scale: scale) || point_after(command) || cursor
            render_line(pixels, attributes, current_attribute, command, counters, from, cursor)
          when 2
            cursor = render_family2(pixels, attributes, current_attribute, command, counters, cursor, scale)
          when 3
            cursor = render_gosub(pixels, attributes, current_attribute, command, counters, cursor, gosub_stack)
          when 4
            render_character(pixels, attributes, current_attribute, command, counters)
          when 5, 6
            fill_paper_attribute_polygon(attributes, current_attribute) if closing_explicit_paper?(command)
            starting_paper = starting_explicit_paper?(command)
            reset_paper_attribute_path if starting_paper
            if update_attribute(current_attribute, command)
              start_paper_attribute_path(current_attribute) if starting_paper
              counters[:commands_rendered] += 1
            else
              skip(counters)
            end
          else
            skip(counters)
          end
        end
        cursor
      end

      def render_gosub(pixels, attributes, current_attribute, command, counters, cursor, gosub_stack)
        picture_id = command["picture"]
        picture_commands = pictures_by_id[picture_id]
        return cursor.tap { skip(counters) } unless @render_gosubs && picture_commands && !gosub_stack.include?(picture_id)

        render_commands(
          pixels,
          attributes,
          current_attribute,
          picture_commands,
          counters,
          cursor: cursor,
          gosub_stack: gosub_stack + [picture_id],
          scale: gosub_scale(command),
        )
      end

      def render_plot(pixels, attributes, current_attribute, command, counters, point)
        return skip(counters) unless point_in_range?(point)

        if pixel_neutral?(command)
          set_draw_attribute_for_pixel(attributes, point.fetch("x"), bitmap_y(point.fetch("y")), current_attribute)
          counters[:commands_rendered] += 1
          return
        end

        plot(pixels, attributes, current_attribute, point.fetch("x"), point.fetch("y"), command)
        counters[:commands_rendered] += 1
      end

      def render_line(pixels, attributes, current_attribute, command, counters, from, to)
        return skip(counters) if pixel_neutral?(command)

        return skip(counters) unless point_in_range?(from) && point_in_range?(to)

        draw_line(pixels, attributes, current_attribute, from.fetch("x"), from.fetch("y"), to.fetch("x"), to.fetch("y"), command)
        track_paper_attribute_edge(current_attribute, from, to)
        counters[:commands_rendered] += 1
      end

      def render_family2(pixels, attributes, current_attribute, command, counters, cursor, scale)
        if attribute_block?(command)
          apply_attribute_block(attributes, current_attribute, command)
          counters[:commands_rendered] += 1
          return cursor
        end
        return cursor.tap { skip(counters) } if family2_block?(command)

        point = relative_point(command, cursor, scale: scale) || command["tip"]
        return cursor.tap { skip(counters) } unless point_in_range?(point)

        case family2_mode
        when :seeds
          render_family2_seed(pixels, attributes, current_attribute, point, counters)
        when :solid_fill
          render_family2_fill(pixels, attributes, current_attribute, point, counters) { true }
        when :checker_fill
          render_family2_fill(pixels, attributes, current_attribute, point, counters) { |x, y| ((x / 4) + (y / 4)).even? }
        when :diagonal_fill
          render_family2_fill(pixels, attributes, current_attribute, point, counters) { |x, y| ((x + y) % 4).zero? }
        when :reverse_diagonal_fill
          render_family2_fill(pixels, attributes, current_attribute, point, counters) { |x, y| ((x - y) % 4).zero? }
        when :shade_byte_fill
          if command["name"] == "flood_fill"
            render_family2_fill(pixels, attributes, current_attribute, point, counters, command: command) { true }
          else
            pattern_byte = command["pattern_byte"]
            render_family2_fill(pixels, attributes, current_attribute, point, counters, command: command) do |x, y|
              ShadePattern.pixel?(pattern_byte, x, y, patterns: shade_patterns, inverse: command["inverse_bit"] == true)
            end
          end
        else
          skip(counters)
        end
        cursor
      end

      def render_family2_seed(pixels, attributes, current_attribute, point, counters)
        x = point.fetch("x")
        y = point.fetch("y")
        plot(pixels, attributes, current_attribute, x, y)
        plot(pixels, attributes, current_attribute, x - 1, y) if x.positive?
        plot(pixels, attributes, current_attribute, x + 1, y) if x < WIDTH - 1
        plot(pixels, attributes, current_attribute, x, y - 1) if y.positive?
        plot(pixels, attributes, current_attribute, x, y + 1) if y < GRAPHICS_HEIGHT - 1
        counters[:commands_rendered] += 1
      end

      def render_family2_fill(pixels, attributes, current_attribute, point, counters, command: nil, &pattern)
        seed_y = bitmap_y(point.fetch("y"))
        bounded = bounded_region(pixels, point.fetch("x"), seed_y)
        return skip(counters) if bounded.empty?

        region = bounded
        if command && command["name"] == "shade_fill"
          region = monotone_bidirectional_region(pixels, point.fetch("x"), seed_y)
          if @preserve_paper_on_pixel_attributes && command.fetch("opcode", 0).to_i == 0x62
            fringe = (bounded - region).select { |x, y| y > seed_y && pattern.call(x, y) }
            region = (region + fringe).uniq
          end
          return skip(counters) if region.empty?
        elsif command && command["name"] == "flood_fill"
          region = monotone_bidirectional_region(pixels, point.fetch("x"), seed_y)
          region = remove_flood_fill_upper_side_overhang(region, point.fetch("x"), seed_y)
          region = remove_flood_fill_left_edge_cap(region, pixels)
          region = preserve_flood_fill_entry_character_cells(region, point.fetch("x"))
          return skip(counters) if region.empty?
        else
          fill_points = region.select { |x, y| pattern.call(x, y) }
          if region_touches_edge?(region) && fill_points.length > MAX_EDGE_FILL_PIXELS
            region = monotone_bidirectional_region(pixels, point.fetch("x"), seed_y)
            return skip(counters) if region.empty?
          end
        end

        cap_sensitive = shade_cap_sensitive?(command)
        before_pixels = cap_sensitive ? pixels.map(&:dup) : nil
        region_set = cap_sensitive ? region.to_h { |pixel| [pixel, true] } : nil
        region.each do |x, y|
          value = pattern.call(x, y)
          value = false if value && cap_sensitive && skip_shade_cap?(before_pixels, region_set, x, y, command["pattern_byte"].to_i, seed_y)
          pixels[y][x] = value
          if command && command["name"] == "flood_fill"
            set_draw_attribute_for_pixel(attributes, x, y, current_attribute)
          else
            set_attribute_for_pixel(attributes, x, y, current_attribute)
          end
        end
        counters[:commands_rendered] += 1
      end

      def remove_flood_fill_upper_side_overhang(region, start_x, start_y)
        return region if region.empty?

        rows = region.group_by(&:last)
        # PAW scan fill does not climb into one-row upper side overhangs; a
        # couple of captured game traces isolate the case (e.g. offsets 1223
        # and 1260 of one picture's drawstring table). Offset 406 shows the
        # same rule across a two-row branch: once the immediately adjacent row
        # above the seed is already wholly to the side of the seed column,
        # PAW leaves that upper branch for a later seed instead of claiming
        # it from the lower fill. A different picture (offset 118) shows the
        # symmetric left-hand case.
        adjacent_top = rows[start_y - 1]
        return region unless adjacent_top

        adjacent_xs = adjacent_top.map(&:first)
        top_to_right = adjacent_xs.min > start_x
        top_to_left = adjacent_xs.max < start_x
        return region unless top_to_right || top_to_left

        region - rows.select do |y, row|
          next false unless y < start_y

          row_xs = row.map(&:first)
          top_to_right ? row_xs.min > start_x : row_xs.max < start_x
        end.values.flatten(1)
      end

      def remove_flood_fill_left_edge_cap(region, pixels)
        region.reject do |x, y|
          x.zero? && y < GRAPHICS_HEIGHT - 1 && pixels[y][x + 1] && pixels[y + 1][x]
        end
      end

      def preserve_flood_fill_entry_character_cells(region, seed_x)
        return region if @drawn_character_cells.empty? || region.empty?

        protected = []
        by_row = @drawn_character_cells.keys.group_by(&:last)
        by_row.each do |char_y, cells|
          cells.map(&:first).sort.slice_when do |left, right|
            right != left + 1 || @drawn_character_cells[[left, char_y]] != @drawn_character_cells[[right, char_y]]
          end.each do |run|
            next if run.length < 3

            left = run.first
            right = run.last
            protected_x = if seed_x < left * 8
              left
            elsif seed_x > right * 8 + 7
              right
            end
            next unless protected_x

            region.each do |x, y|
              protected << [x, y] if x / 8 == protected_x && y / 8 == char_y
            end
          end
        end

        return region if protected.empty?

        region - protected
      end

      def shade_cap_sensitive?(command)
        command && command["name"] == "shade_fill" && [0x00, 0x11, 0x21, 0xFF].include?(command["pattern_byte"].to_i)
      end

      def skip_shade_cap?(pixels, region_set, x, y, pattern_byte, seed_y)
        return false unless y.between?(1, GRAPHICS_HEIGHT - 2)

        # PAW's 0x21 shade pass leaves this capped one-pixel recess untouched in
        # a handful of captured location traces. Use the pre-fill bitmap so
        # earlier shaded pixels in the same region do not manufacture new caps.
        return true if @preserve_paper_on_pixel_attributes &&
          pattern_byte == 0x00 &&
          x.zero? &&
          y < GRAPHICS_HEIGHT - 1 &&
          pixels[y][x + 1] &&
          !pixels[y + 1][x]

        if pattern_byte == 0x21 && x.between?(1, WIDTH - 2)
          return true if pixels[y][x - 1] &&
            pixels[y][x + 1] &&
            pixels[y - 1][x] &&
            pixels[y - 1][x - 1] &&
            pixels[y - 1][x + 1] &&
            pixels[y + 1][x + 1] &&
            region_set[[x, y + 1]]
        end

        return true if @preserve_paper_on_pixel_attributes &&
          pattern_byte == 0x11 &&
          y == seed_y - 1 &&
          (y % 8) == 3 &&
          pixels[y - 1][x] &&
          !pixels[y][x - 1] &&
          !pixels[y][x + 1] &&
          !pixels[y + 1][x] &&
          region_set[[x, y + 1]]

        # The solid 0xFF shade pass shows the same edge-cap behavior at the left
        # screen border: PAW leaves the corner outside the right and lower
        # boundaries clear.
        pattern_byte == 0xFF && x.zero? && pixels[y][x + 1] && pixels[y + 1][x]
      end

      def render_character(pixels, attributes, current_attribute, command, counters)
        glyph = glyph_for(command["character"])
        char_x = command["character_x"]
        char_y = command["character_y"]
        return skip(counters) unless glyph && char_x && char_y

        origin_x = char_x * 8
        origin_y = char_y * 8
        return skip(counters) unless origin_x.between?(0, WIDTH - 8) && origin_y.between?(0, HEIGHT - 8)

        @drawn_character_cells[[char_x, char_y]] = command["character"]

        glyph.each_with_index do |row, y|
          row.each_char.with_index do |pixel, x|
            pixels[origin_y + y][origin_x + x] = pixel == "1"
            set_attribute_for_pixel(attributes, origin_x + x, origin_y + y, current_attribute)
          end
        end
        counters[:commands_rendered] += 1
      end

      def skip(counters)
        counters[:commands_skipped] += 1
      end

      def normalize_pictures_by_id(pictures)
        return {} unless pictures

        entries = pictures.is_a?(Hash) && pictures.key?("entries") ? pictures.fetch("entries") : pictures
        case entries
        when Hash
          entries.transform_keys(&:to_i).transform_values do |entry|
            entry.is_a?(Hash) && entry.key?("decoded_commands") ? entry.fetch("decoded_commands") : entry
          end
        else
          entries.to_h { |entry| [entry.fetch("id"), entry.fetch("decoded_commands")] }
        end
      end

      def origin_point
        { "x" => 0, "y" => 0 }
      end

      def absolute_point(command)
        if command.key?("x") && command.key?("y")
          { "x" => command.fetch("x").to_i, "y" => command.fetch("y").to_i }
        elsif command["point_after"]
          point = command["point_after"]
          { "x" => point.fetch("x").to_i, "y" => point.fetch("y").to_i }
        end
      end

      def relative_point(command, cursor, scale: 0)
        dx = command["dx"]
        dy = command["dy"]
        return nil if dx.nil? || dy.nil?

        {
          "x" => cursor.fetch("x") + scaled_delta(dx, scale),
          "y" => cursor.fetch("y") + scaled_delta(dy, scale),
        }
      end

      def gosub_scale(command)
        scale = command.fetch("scale", 0).to_i
        scale.between?(1, 7) ? scale : 0
      end

      def scaled_delta(delta, scale)
        delta = delta.to_i
        scale = scale.to_i
        return delta if scale.zero?

        magnitude = delta.abs * scale / 8
        delta.negative? ? -magnitude : magnitude
      end

      def command_delta?(command)
        command.key?("dx") && command.key?("dy")
      end

      def normalize_charset_glyphs(charsets, charset_id)
        return {} unless charsets

        entries = charsets.fetch("entries", [])
        active_id = (charset_id || charsets["active"] || 1).to_i
        active = entries.find { |entry| entry.fetch("id").to_i == active_id } || entries.first
        return {} unless active

        normalize_glyph_map(active.fetch("glyphs", {}))
      end

      def normalize_udg_glyphs(udgs)
        return {} unless udgs

        normalize_glyph_map(udgs.fetch("glyphs", {}))
      end

      def normalize_shade_patterns(shade_patterns)
        return nil unless shade_patterns

        patterns = shade_patterns.fetch("patterns", shade_patterns)
        patterns.each_with_object({}) do |(pattern_id, bytes), normalized|
          next unless bytes.is_a?(Array) && bytes.length == 8

          normalized[pattern_id.to_i] = bytes.map { |byte| byte.to_i & 0xFF }
        end
      end

      def normalize_glyph_map(glyphs)
        glyphs.each_with_object({}) do |(code, bytes), normalized|
          next unless bytes.is_a?(Array) && bytes.length == 8

          normalized[code.to_i] = bytes.map { |byte| byte.to_i.to_s(2).rjust(8, "0")[-8, 8] }
        end
      end

      def glyph_for(code)
        code = code.to_i
        GLYPHS[code] ||
          charset_glyphs[code] ||
          spectrum_block_graphic_glyph(code) ||
          udg_glyphs[code]
      end

      def spectrum_block_graphic_glyph(code)
        mask = code - 128
        return nil unless mask.between?(0, 15)

        top = +""
        bottom = +""
        top << ((mask & 0x01).zero? ? "0000" : "1111")
        top << ((mask & 0x02).zero? ? "0000" : "1111")
        bottom << ((mask & 0x04).zero? ? "0000" : "1111")
        bottom << ((mask & 0x08).zero? ? "0000" : "1111")
        [top, top, top, top, bottom, bottom, bottom, bottom]
      end

      def point_in_range?(point)
        return false unless point

        point.fetch("x").between?(0, WIDTH - 1) && point.fetch("y").between?(0, GRAPHICS_HEIGHT - 1)
      end

      def pixel_neutral?(command)
        return (command.fetch("opcode").to_i & 0x18) == 0x18 if pixel_effect_opcode?(command)

        command["pixel_effect"] == "move"
      end

      def family2_block?(command)
        command["opcode"] == 0x12 || command["current_parse_length"] == 5
      end

      def point_after(command)
        command["point_after"]
      end

      def plot(pixels, attributes, current_attribute, x, y, command = nil)
        write_pixel(pixels, attributes, current_attribute, x, bitmap_y(y), command)
      end

      def draw_line(pixels, attributes, current_attribute, x0, y0, x1, y1, command = nil)
        y0 = bitmap_y(y0)
        y1 = bitmap_y(y1)
        dx = (x1 - x0).abs
        sx = x0 < x1 ? 1 : -1
        dy = -(y1 - y0).abs
        sy = y0 < y1 ? 1 : -1
        error = dx + dy

        first_point = true
        loop do
          write_pixel(pixels, attributes, current_attribute, x0, y0, command) unless first_point
          break if x0 == x1 && y0 == y1

          first_point = false
          e2 = 2 * error
          if e2 >= dy
            error += dy
            x0 += sx
          end
          if e2 <= dx
            error += dx
            y0 += sy
          end
        end
      end

      def count_pixels(pixels)
        pixels.sum { |row| row.count(true) }
      end

      def set_pixel(pixels, x, y)
        pixels[y][x] = true
      end

      def write_pixel(pixels, attributes, current_attribute, x, y, command)
        return unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)

        if command && over_pixel?(command)
          pixels[y][x] = !pixels[y][x] unless inverse_pixel?(command)
        elsif command && inverse_pixel?(command)
          pixels[y][x] = false
        else
          set_pixel(pixels, x, y)
        end
        set_attribute_for_pixel(attributes, x, y, current_attribute)
      end

      def normalize_attribute(attribute)
        {
          "ink" => normalize_colour(attribute && (attribute["ink"] || attribute[:ink]), default: 0),
          "paper" => normalize_colour(attribute && (attribute["paper"] || attribute[:paper]), default: 7),
          "bright" => normalize_toggle(attribute && (attribute["bright"] || attribute[:bright]), default: false),
          "flash" => normalize_toggle(attribute && (attribute["flash"] || attribute[:flash]), default: false),
          "paper_explicit" => !!(attribute && (attribute["paper_explicit"] || attribute[:paper_explicit])),
        }
      end

      def normalize_colour(value, default:)
        value = default if value.nil?
        code = value.to_i
        code == 8 ? 8 : (code & 7)
      end

      def normalize_toggle(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        code = value.to_i
        code == 8 ? 8 : code != 0
      end

      def update_attribute(attribute, command)
        case command["control"]
        when "ink"
          attribute["ink"] = normalize_colour(command.fetch("control_value", command.fetch("value", attribute.fetch("ink"))), default: attribute.fetch("ink"))
        when "paper"
          attribute["paper"] = normalize_colour(command.fetch("control_value", command.fetch("value", attribute.fetch("paper"))), default: attribute.fetch("paper"))
          attribute["paper_explicit"] = true
        when "bright"
          attribute["bright"] = normalize_toggle(command.fetch("control_value", command.fetch("value", attribute.fetch("bright"))), default: attribute.fetch("bright"))
        when "flash"
          attribute["flash"] = normalize_toggle(command.fetch("control_value", command.fetch("value", attribute.fetch("flash"))), default: attribute.fetch("flash"))
        else
          return false
        end
        true
      end

      def starting_explicit_paper?(command)
        command["control"] == "paper" && command.fetch("control_value", command.fetch("value", 0)).to_i != 0
      end

      def closing_explicit_paper?(command)
        command["control"] == "paper" && command.fetch("control_value", command.fetch("value", 0)).to_i == 0
      end

      def start_paper_attribute_path(_attribute)
        @paper_attribute_path = []
        @paper_attribute_fill_attribute = nil
      end

      def reset_paper_attribute_path
        @paper_attribute_path = []
        @paper_attribute_fill_attribute = nil
      end

      def track_paper_attribute_edge(attribute, from, to)
        return unless attribute["paper_explicit"] && attribute.fetch("paper").to_i != 0

        @paper_attribute_fill_attribute ||= drawable_attribute(attribute).dup
        from_point = [from.fetch("x"), bitmap_y(from.fetch("y"))]
        to_point = [to.fetch("x"), bitmap_y(to.fetch("y"))]
        @paper_attribute_path << from_point if @paper_attribute_path.empty? || @paper_attribute_path.last != from_point
        @paper_attribute_path << to_point
      end

      def fill_paper_attribute_polygon(attributes, current_attribute)
        return reset_paper_attribute_path if @paper_attribute_path.length < 3

        polygon = @paper_attribute_path
        min_ax = [[polygon.map(&:first).min / 8, 0].max, (WIDTH / 8) - 1].min
        max_ax = [[polygon.map(&:first).max / 8, 0].max, (WIDTH / 8) - 1].min
        min_ay = [[polygon.map(&:last).min / 8, 0].max, (HEIGHT / 8) - 1].min
        max_ay = [[polygon.map(&:last).max / 8, 0].max, (HEIGHT / 8) - 1].min

        min_ay.upto(max_ay) do |ay|
          min_ax.upto(max_ax) do |ax|
            next unless attribute_cell_covered_by_polygon?(ax, ay, polygon)

            attributes[ay][ax] = (@paper_attribute_fill_attribute || drawable_attribute(current_attribute)).dup
          end
        end
      ensure
        reset_paper_attribute_path
      end

      def point_inside_polygon?(point, polygon)
        x, y = point
        inside = false
        j = polygon.length - 1
        polygon.each_with_index do |current, i|
          xi, yi = current
          xj, yj = polygon[j]
          if (yi > y) != (yj > y)
            x_intersection = (xj - xi) * (y - yi).to_f / (yj - yi) + xi
            inside = !inside if x < x_intersection
          end
          j = i
        end
        inside
      end

      def attribute_cell_covered_by_polygon?(ax, ay, polygon)
        min_y = polygon.map(&:last).min
        max_y = polygon.map(&:last).max
        center_y = ay * 8 + 4
        return false unless center_y.between?(min_y, max_y - 1)

        covered = 0
        8.times do |dy|
          8.times do |dx|
            covered += 1 if point_inside_polygon?([ax * 8 + dx, ay * 8 + dy], polygon)
          end
        end
        covered >= 6
      end

      def attribute_block?(command)
        command["name"] == "attribute_block" && command["attribute_block"]
      end

      def apply_attribute_block(attributes, current_attribute, command)
        block = command.fetch("attribute_block")
        x0 = block.fetch("attribute_x").to_i
        y0 = block.fetch("attribute_y").to_i
        width = block.fetch("width_attributes").to_i
        height = block.fetch("height_attributes").to_i

        y0.upto(y0 + height - 1) do |ay|
          next unless ay.between?(0, attributes.length - 1)

          x0.upto(x0 + width - 1) do |ax|
            next unless ax.between?(0, attributes.fetch(ay).length - 1)

            attributes[ay][ax] = merge_draw_attribute(attributes[ay][ax], current_attribute)
          end
        end
      end

      def set_attribute_for_pixel(attributes, x, y, current_attribute)
        return unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)

        ax = x / 8
        ay = y / 8
        return unless ay.between?(0, attributes.length - 1) && ax.between?(0, attributes.fetch(ay).length - 1)

        attributes[ay][ax] = merge_pixel_attribute(attributes[ay][ax], current_attribute)
      end

      def set_draw_attribute_for_pixel(attributes, x, y, current_attribute)
        return unless x.between?(0, WIDTH - 1) && y.between?(0, HEIGHT - 1)

        ax = x / 8
        ay = y / 8
        return unless ay.between?(0, attributes.length - 1) && ax.between?(0, attributes.fetch(ay).length - 1)

        attributes[ay][ax] = merge_draw_attribute(attributes[ay][ax], current_attribute)
      end

      def merge_draw_attribute(existing, current_attribute)
        merged = existing.dup
        merged["ink"] = current_attribute.fetch("ink") unless current_attribute.fetch("ink") == 8
        merged["paper"] = current_attribute.fetch("paper") unless current_attribute.fetch("paper") == 8
        merged["bright"] = current_attribute.fetch("bright") unless current_attribute.fetch("bright") == 8
        merged["flash"] = current_attribute.fetch("flash") unless current_attribute.fetch("flash") == 8
        drawable_attribute(merged)
      end

      def merge_pixel_attribute(existing, current_attribute)
        return merge_draw_attribute(existing, current_attribute) unless @preserve_paper_on_pixel_attributes
        return merge_draw_attribute(existing, current_attribute) if current_attribute["paper_explicit"]

        merged = existing.dup
        merged["ink"] = current_attribute.fetch("ink") unless current_attribute.fetch("ink") == 8
        merged["bright"] = current_attribute.fetch("bright") unless current_attribute.fetch("bright") == 8
        merged["flash"] = current_attribute.fetch("flash") unless current_attribute.fetch("flash") == 8
        drawable_attribute(merged)
      end

      def drawable_attribute(attribute)
        attribute.reject { |key, _| key == "paper_explicit" }.tap do |drawable|
          drawable["ink"] &= 7 if drawable["ink"]
          drawable["paper"] &= 7 if drawable["paper"]
        end
      end

      def inverse_pixel?(command)
        return (command.fetch("opcode").to_i & 0x10) != 0 if pixel_effect_opcode?(command)

        command["inverse_bit"] == true
      end

      def over_pixel?(command)
        return (command.fetch("opcode").to_i & 0x08) != 0 if pixel_effect_opcode?(command)

        command["over_bit"] == true
      end

      def pixel_effect_opcode?(command)
        command && command.key?("opcode") && [0, 1, 2].include?(command["family"].to_i)
      end

      def bitmap_y(graphics_y)
        GRAPHICS_HEIGHT - 1 - graphics_y
      end

      def bounded_region(pixels, start_x, start_y)
        return [] unless start_x.between?(0, WIDTH - 1) && start_y.between?(0, GRAPHICS_HEIGHT - 1)
        return [] if pixels[start_y][start_x]

        visited = Array.new(GRAPHICS_HEIGHT) { Array.new(WIDTH, false) }
        queue = [[start_x, start_y]]
        visited[start_y][start_x] = true
        region = []
        escaped = false

        until queue.empty?
          x, y = queue.shift
          region << [x, y]
          escaped ||= x.zero? || x == WIDTH - 1 || y.zero? || y == GRAPHICS_HEIGHT - 1
          return [] if escaped && !@allow_edge_fills
          return [] if region.length > MAX_FILL_PIXELS

          [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]].each do |nx, ny|
            next unless nx.between?(0, WIDTH - 1) && ny.between?(0, GRAPHICS_HEIGHT - 1)
            next if visited[ny][nx] || pixels[ny][nx]

            visited[ny][nx] = true
            queue << [nx, ny]
          end
        end

        region
      end

      def monotone_bidirectional_region(pixels, start_x, start_y)
        (monotone_region(pixels, start_x, start_y, -1) + monotone_region(pixels, start_x, start_y, 1)).uniq
      end

      def monotone_region(pixels, start_x, start_y, dy)
        visited = Array.new(GRAPHICS_HEIGHT) { Array.new(WIDTH, false) }
        points = []
        active = spans_overlapping(pixels, visited, start_x..start_x, start_y)
        y = start_y

        until active.empty?
          active.each do |left, right|
            left.upto(right) do |x|
              next if visited[y][x] || pixels[y][x]

              visited[y][x] = true
              points << [x, y]
            end
          end

          return [] if points.length > MAX_FILL_PIXELS

          y += dy
          break unless y.between?(0, GRAPHICS_HEIGHT - 1)

          # Dedupe overlapping spans: when input ranges overlap or touch, the
          # per-range `spans_overlapping` calls can produce overlapping output
          # spans that, without dedup, compound quadratically on every row.
          next_active = active.flat_map { |left, right| spans_overlapping(pixels, visited, left..right, y) }
          active = merge_overlapping_spans(next_active)
        end

        points
      end

      def merge_overlapping_spans(spans)
        return [] if spans.empty?

        sorted = spans.sort_by { |left, _right| left }
        merged = [sorted.first]
        sorted.drop(1).each do |left, right|
          prev_left, prev_right = merged.last
          if left <= prev_right + 1
            merged[-1] = [prev_left, [prev_right, right].max]
          else
            merged << [left, right]
          end
        end
        merged
      end

      def spans_overlapping(pixels, visited, range, y)
        spans = []
        x = range.begin
        while x <= range.end
          if x.between?(0, WIDTH - 1) && !pixels[y][x] && !visited[y][x]
            left = x
            left -= 1 while left.positive? && !pixels[y][left - 1] && !visited[y][left - 1]
            right = x
            right += 1 while right < WIDTH - 1 && !pixels[y][right + 1] && !visited[y][right + 1]
            spans << [left, right]
            x = right
          end
          x += 1
        end
        spans
      end

      def region_touches_edge?(region)
        region.any? do |x, y|
          x.zero? || x == WIDTH - 1 || y.zero? || y == GRAPHICS_HEIGHT - 1
        end
      end
    end
  end
end
