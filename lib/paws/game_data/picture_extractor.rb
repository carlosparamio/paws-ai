# frozen_string_literal: true

require_relative "drawstring_decoder"

module PAWS
  module GameData
    # Extracts PAWS picture metadata and raw drawstring bytes without decoding
    # the drawstring command language.
    class PictureExtractor
      DRAWABLE_BIT = 0x80
      COLOR_MASK = 0x07
      PAPER_SHIFT = 3

      def initialize(sna:, drawstring_decoder: DrawstringDecoder.new)
        @sna = sna
        @drawstring_decoder = drawstring_decoder
      end

      def extract(drawstrings_start:, picture_table:, location_flags:, graphics_end:, location_count:, flags_before_drawstrings: false)
        return nil unless valid_layout?(
          drawstrings_start: drawstrings_start,
          picture_table: picture_table,
          location_flags: location_flags,
          graphics_end: graphics_end,
          location_count: location_count,
          flags_before_drawstrings: flags_before_drawstrings,
        )

        entries = build_entries(
          drawstrings_start: drawstrings_start,
          drawstrings_end: drawstrings_end(
            drawstrings_start: drawstrings_start,
            picture_table: picture_table,
            location_flags: location_flags,
            flags_before_drawstrings: flags_before_drawstrings,
          ),
          picture_table: picture_table,
          location_flags: location_flags,
          location_count: location_count,
          flags_before_drawstrings: flags_before_drawstrings,
        )

        return nil unless contains_graphics?(entries, drawstrings_start, location_flags)

        {
          "drawstrings_start" => drawstrings_start,
          "picture_table" => picture_table,
          "location_flags" => location_flags,
          "graphics_end" => graphics_end,
          "summary" => picture_summary(entries),
          "entries" => entries,
        }
      end

      private

      attr_reader :sna

      def valid_layout?(drawstrings_start:, picture_table:, location_flags:, graphics_end:, location_count:, flags_before_drawstrings:)
        return false unless positive_address?(drawstrings_start)
        return false unless positive_address?(picture_table)
        return false unless positive_address?(graphics_end)
        return false unless location_count.positive?
        return false unless picture_table + location_count * 2 <= graphics_end
        return false if location_flags && location_flags + location_count > graphics_end
        return false unless if flags_before_drawstrings
                              location_flags && location_flags < drawstrings_start && drawstrings_start < picture_table
                            elsif location_flags
                              drawstrings_start < [picture_table, location_flags].min
                            else
                              drawstrings_start < picture_table
                            end

        graphics_end <= 65_535
      end

      def positive_address?(value)
        value.is_a?(Integer) && value.positive?
      end

      def build_entries(drawstrings_start:, drawstrings_end:, picture_table:, location_flags:, location_count:, flags_before_drawstrings:)
        pointers = location_count.times.map { |index| sna.peek_word(picture_table + index * 2) }
        effective_pointers = effective_pointers(
          pointers,
          drawstrings_start: drawstrings_start,
          drawstrings_end: drawstrings_end,
          location_flags: location_flags,
          flags_before_drawstrings: flags_before_drawstrings,
        )

        location_count.times.map do |id|
          pointer = effective_pointers[id]
          length = drawstring_length(pointer, effective_pointers, drawstrings_start, drawstrings_end)
          bytes = raw_bytes(pointer, length)
          flag = location_flags ? sna.peek(location_flags + id) : default_flag(bytes)

          {
            "id" => id,
            "pointer" => pointers[id],
            "effective_pointer" => pointer,
            "length" => length,
            "location_flag" => flag,
            "drawable" => drawable?(flag),
            "paper" => paper(flag),
            "ink" => ink(flag),
            "raw_bytes" => bytes,
          }
            .then { |entry| entry.merge(decoded_drawstring(entry.fetch("raw_bytes"), location_count)) }
        end
      end

      def drawstrings_end(drawstrings_start:, picture_table:, location_flags:, flags_before_drawstrings:)
        return picture_table if flags_before_drawstrings || location_flags.nil?

        [picture_table, location_flags].min
      end

      def effective_pointers(pointers, drawstrings_start:, drawstrings_end:, location_flags:, flags_before_drawstrings:)
        return pointers unless flags_before_drawstrings

        effective = pointers.dup
        first_valid = pointers.compact.select { |pointer| pointer >= drawstrings_start && pointer < drawstrings_end }.min
        return effective unless first_valid && first_valid > drawstrings_start

        leading_invalid = pointers.each_with_index.take_while do |pointer, index|
          pointer == location_flags + index
        end
        return effective if leading_invalid.empty?

        target_index = leading_invalid.last.last
        effective[target_index] = drawstrings_start
        leading_invalid[0...-1].each { |_pointer, index| effective[index] = nil }
        effective
      end

      def drawstring_length(pointer, pointers, drawstrings_start, drawstrings_end)
        return 0 unless pointer
        return 0 if pointer < drawstrings_start || pointer >= drawstrings_end

        following_pointer = pointers.compact.select { |candidate| candidate > pointer && candidate <= drawstrings_end }.min
        (following_pointer || drawstrings_end) - pointer
      end

      def raw_bytes(pointer, length)
        return [] unless pointer && length.positive?

        length.times.map { |offset| sna.peek(pointer + offset) }
      end

      def decoded_drawstring(raw_bytes, location_count)
        decoded = drawstring_decoder.decode(raw_bytes)
        warnings = decoded.fetch("warnings") + invalid_gosub_warnings(decoded.fetch("commands"), location_count)
        {
          "decoded_commands" => decoded.fetch("commands"),
          "decode_summary" => decode_summary(decoded.fetch("commands")),
          "decode_warnings" => warnings,
          "decoded_bytes" => decoded.fetch("consumed_bytes"),
        }
      end

      def invalid_gosub_warnings(commands, location_count)
        commands.filter_map do |command|
          next unless command.fetch("family") == 3

          picture = command["picture"]
          next unless picture && picture >= location_count

          "gosub picture out of table at offset #{command.fetch("offset")}: picture=#{picture} location_count=#{location_count}"
        end
      end

      def picture_summary(entries)
        commands = entries.flat_map { |entry| entry.fetch("decoded_commands") }
        {
          "entry_count" => entries.size,
          "drawable_count" => entries.count { |entry| entry.fetch("drawable") },
          "raw_byte_count" => entries.sum { |entry| entry.fetch("length") },
          "decoded_command_count" => commands.size,
          "decode_warning_count" => entries.sum { |entry| entry.fetch("decode_warnings").size },
          "families" => tally(commands) { |command| command.fetch("family").to_s },
          "names" => tally(commands) { |command| command.fetch("name") },
        }
      end

      def decode_summary(commands)
        last_point = commands.reverse_each.find { |command| command.key?("point_after") }
        last_point_value = last_point&.fetch("point_after", nil)

        {
          "command_count" => commands.size,
          "families" => tally(commands) { |command| command.fetch("family").to_s },
          "names" => tally(commands) { |command| command.fetch("name") },
          "last_point" => last_point_value,
        }
      end

      def tally(commands)
        counts = Hash.new(0)
        commands.each { |command| counts[yield(command)] += 1 }
        counts.sort.to_h
      end

      def contains_graphics?(entries, drawstrings_start, location_flags)
        if location_flags.nil? && entries.each_with_index.all? { |entry, index| entry["pointer"] == drawstrings_start + index && entry["length"] == 1 }
          return false
        end

        entries.any? { |entry| entry["drawable"] || entry["raw_bytes"].any? { |byte| byte && byte != 0 } }
      end

      def default_flag(bytes)
        bytes.any? { |byte| byte && byte != 0 && byte != DrawstringDecoder::END_MARKER } ? DRAWABLE_BIT : 0
      end

      def drawable?(flag)
        (flag & DRAWABLE_BIT) != 0
      end

      def paper(flag)
        (flag >> PAPER_SHIFT) & COLOR_MASK
      end

      def ink(flag)
        flag & COLOR_MASK
      end

      attr_reader :drawstring_decoder
    end
  end
end
