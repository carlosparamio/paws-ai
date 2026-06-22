# frozen_string_literal: true

require "json"
require_relative "../graphics/drawstring_preview_renderer"
require_relative "../utils/color_utils"

module PAWS
  module Web
    # Converts decoded PAW picture commands into browser-friendly frame payloads.
    #
    # The browser intentionally receives a compact bitmap frame instead of PAW
    # commands so Ruby remains the source of truth for reverse-engineered
    # graphics semantics.
    class GraphicsPresenter
      WIDTH = PAWS::Graphics::DrawstringPreviewRenderer::WIDTH
      HEIGHT = PAWS::Graphics::DrawstringPreviewRenderer::HEIGHT

      FrameRender = Struct.new(:frame, :render_result, keyword_init: true)

      def initialize(game_data, renderer: nil)
        @game_data = game_data
        @pictures = game_data.fetch("pictures", {})
        @renderer = renderer || PAWS::Graphics::DrawstringPreviewRenderer.new(
          family2_mode: :shade_byte_fill,
          pictures_by_id: @pictures,
          allow_edge_fills: true,
          charsets: game_data["charsets"],
          charset_id: graphics_charset_id,
          udgs: game_data["udgs"],
          shade_patterns: game_data["shade_patterns"],
          preserve_paper_on_pixel_attributes: game_data.dig("game", "paw_version").to_i == 1,
        )
      end

      def frame_for_picture(picture_id, full_screen: false, base_result: nil)
        render_picture(picture_id, full_screen: full_screen, base_result: base_result).frame
      end

      def render_picture(picture_id, full_screen: false, base_result: nil)
        picture = picture_entry(picture_id)
        commands = picture.fetch("decoded_commands", [])
        initial_attribute = initial_attribute_for(picture)
        result = @renderer.render(
          commands,
          initial_attribute: initial_attribute,
          screen_attribute: {
            "ink" => initial_attribute.fetch("ink"),
            "paper" => 0,
          },
          base_pixels: base_result&.pixels,
          base_attributes: base_result&.attributes,
        )

        frame = {
          "type" => "screen.frame",
          "picture_id" => picture_id,
          "logical_width" => WIDTH,
          "logical_height" => HEIGHT,
          "visible_height" => full_screen ? HEIGHT : visible_height(result.pixels),
          "full_screen" => full_screen,
          "content_rect" => content_rect(result.pixels),
          "encoding" => "bitmap_rows",
          "rows" => bitmap_rows(result.pixels),
          "attributes" => result.attributes,
          "commands_seen" => result.commands_seen,
          "commands_rendered" => result.commands_rendered,
          "commands_skipped" => result.commands_skipped,
          "pixels_set" => result.pixels_set,
        }
        overlay_rows = overlay_bitmap_rows(base_result&.pixels, result.pixels)
        frame["overlay_rows"] = overlay_rows if overlay_rows
        toggle_rows = effect_bitmap_rows(commands, :toggle)
        frame["toggle_rows"] = toggle_rows if toggle_rows
        inverse_rows = effect_bitmap_rows(commands, :clear)
        clear_rows = cleared_bitmap_rows(base_result&.pixels, result.pixels)
        clear_rows = merge_bitmap_rows(clear_rows, inverse_rows)
        frame["clear_rows"] = clear_rows if clear_rows

        FrameRender.new(frame: frame, render_result: result)
      end

      def picture_ids
        picture_entries.map { |entry| entry.fetch("id") }
      end

      private

      attr_reader :pictures

      def picture_entry(picture_id)
        picture_entries.find { |entry| entry.fetch("id") == picture_id } ||
          raise(KeyError, "picture #{picture_id} not found")
      end

      def picture_entries
        entries = pictures.fetch("entries", [])
        return entries if entries.is_a?(Array)

        entries.map { |id, entry| entry.merge("id" => id.to_i) }
      end

      def initial_attribute_for(picture)
        if paw_version == 1
          defaults = @game_data.fetch("defaults", {})
          paper = normal_colour(defaults.fetch("paper", 0), fallback: 0)
          ink = contrast_colour(defaults.fetch("ink", 7), paper)
          return { "ink" => ink, "paper" => paper }
        end

        {
          "ink" => picture.fetch("ink", 0),
          "paper" => picture.fetch("paper", 7),
        }
      end

      def paw_version
        @game_data.dig("game", "paw_version").to_i
      end

      def graphics_charset_id
        paw_version == 1 ? 1 : @game_data.dig("defaults", "charset")
      end

      def normal_colour(value, fallback:)
        code = value.to_i
        code.between?(0, 7) ? code : fallback
      end

      def contrast_colour(value, paper)
        code = value.to_i
        return code if code.between?(0, 7)
        return PAWS::ColorUtils::COLORS.fetch(PAWS::ColorUtils.spectrum_color_name(9, contrast_against: paper)) if code == 9

        7
      end

      def bitmap_rows(pixels)
        pixels.map { |row| row.map { |pixel| pixel ? "1" : "0" }.join }
      end

      def overlay_bitmap_rows(base_pixels, pixels)
        return nil unless base_pixels

        any_overlay = false
        rows = pixels.each_with_index.map do |row, y|
          base_row = base_pixels[y] || []
          row.each_with_index.map do |pixel, x|
            overlay = pixel && !base_row[x]
            any_overlay ||= overlay
            overlay ? "1" : "0"
          end.join
        end
        any_overlay ? rows : nil
      end

      def cleared_bitmap_rows(base_pixels, pixels)
        return nil unless base_pixels

        any_cleared = false
        rows = pixels.each_with_index.map do |row, y|
          base_row = base_pixels[y] || []
          row.each_with_index.map do |pixel, x|
            cleared = base_row[x] && !pixel
            any_cleared ||= cleared
            cleared ? "1" : "0"
          end.join
        end
        any_cleared ? rows : nil
      end

      def merge_bitmap_rows(left, right)
        return right unless left
        return left unless right

        any_set = false
        rows = left.each_with_index.map do |left_row, y|
          right_row = right[y] || ""
          left_row.chars.each_with_index.map do |pixel, x|
            set = pixel == "1" || right_row[x] == "1"
            any_set ||= set
            set ? "1" : "0"
          end.join
        end
        any_set ? rows : nil
      end

      def effect_bitmap_rows(commands, effect)
        pixels = Array.new(HEIGHT) { Array.new(WIDTH, false) }
        draw_effect_commands(pixels, commands, effect, cursor: { "x" => 0, "y" => 0 }, gosub_stack: [], scale: 0)
        rows = bitmap_rows(pixels)
        rows.any? { |row| row.include?("1") } ? rows : nil
      end

      def draw_effect_commands(pixels, commands, effect, cursor:, gosub_stack:, scale:)
        cursor = cursor.dup
        commands.each do |command|
          case command["family"]
          when 0
            cursor = absolute_point(command) || cursor
            mark_effect_plot(pixels, command, effect, cursor)
          when 1
            from = command_delta?(command) ? cursor : (command["point_before"] || cursor)
            cursor = relative_point(command, cursor, scale: scale) || command["point_after"] || cursor
            mark_effect_line(pixels, command, effect, from, cursor)
          when 3
            picture_id = command["picture"]
            picture_commands = pictures_by_id[picture_id]
            next unless picture_commands && !gosub_stack.include?(picture_id)

            cursor = draw_effect_commands(
              pixels,
              picture_commands,
              effect,
              cursor: cursor,
              gosub_stack: gosub_stack + [picture_id],
              scale: gosub_scale(command),
            )
          end
        end
        cursor
      end

      def mark_effect_plot(pixels, command, effect, point)
        return unless command_pixel_effect(command) == effect
        return unless point_in_range?(point)

        mark_effect_pixel(pixels, point.fetch("x"), bitmap_y(point.fetch("y")), effect)
      end

      def mark_effect_line(pixels, command, effect, from, to)
        return unless command_pixel_effect(command) == effect
        return unless point_in_range?(from) && point_in_range?(to)

        raster_line(from.fetch("x"), bitmap_y(from.fetch("y")), to.fetch("x"), bitmap_y(to.fetch("y"))) do |x, y|
          mark_effect_pixel(pixels, x, y, effect)
        end
      end

      def mark_effect_pixel(pixels, x, y, effect)
        if effect == :toggle
          pixels[y][x] = !pixels[y][x]
        else
          pixels[y][x] = true
        end
      end

      def raster_line(x0, y0, x1, y1)
        dx = (x1 - x0).abs
        sx = x0 < x1 ? 1 : -1
        dy = -(y1 - y0).abs
        sy = y0 < y1 ? 1 : -1
        error = dx + dy
        first_point = true

        loop do
          yield x0, y0 unless first_point
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

      def command_pixel_effect(command)
        return :move if pixel_neutral?(command)
        return :toggle if over_pixel?(command)
        return :clear if inverse_pixel?(command)

        :set
      end

      def content_rect(pixels)
        points = []
        pixels.each_with_index do |row, y|
          row.each_with_index { |pixel, x| points << [x, y] if pixel }
        end
        return { "x" => 0, "y" => 0, "width" => WIDTH, "height" => 96 } if points.empty?

        xs = points.map(&:first)
        ys = points.map(&:last)
        {
          "x" => xs.min,
          "y" => ys.min,
          "width" => xs.max - xs.min + 1,
          "height" => ys.max - ys.min + 1,
        }
      end

      def visible_height(pixels)
        rect = content_rect(pixels)
        rounded = ((rect.fetch("y") + rect.fetch("height") + 7) / 8) * 8
        [[rounded, 96].max, HEIGHT].min
      end

      def pictures_by_id
        @pictures_by_id ||= picture_entries.to_h { |entry| [entry.fetch("id").to_i, entry.fetch("decoded_commands", [])] }
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

      def point_in_range?(point)
        return false unless point

        point.fetch("x").between?(0, WIDTH - 1) && point.fetch("y").between?(0, PAWS::Graphics::DrawstringPreviewRenderer::GRAPHICS_HEIGHT - 1)
      end

      def bitmap_y(graphics_y)
        PAWS::Graphics::DrawstringPreviewRenderer::GRAPHICS_HEIGHT - 1 - graphics_y
      end

      def pixel_neutral?(command)
        return (command.fetch("opcode").to_i & 0x18) == 0x18 if pixel_effect_opcode?(command)

        command["pixel_effect"] == "move"
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
    end
  end
end
