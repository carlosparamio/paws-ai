# frozen_string_literal: true

module PAWS
  module GameData
    # Extracts PAWS character-set banks from the SNA memory image.
    #
    # PAWS stores custom fonts as contiguous Spectrum 8x8 glyphs for character
    # codes 32..127. The default charset number in the header is 1-based, so the
    # exported entries use the same ids that CHARS/CHARSET condacts refer to.
    class CharsetExtractor
      FIRST_CHAR = 32
      CHAR_COUNT = 96
      BYTES_PER_CHAR = 8
      BANK_SIZE = CHAR_COUNT * BYTES_PER_CHAR
      MEMORY_LIMIT = 65_536
      SYSVAR_UDG = 23_675
      FIRST_UDG = 144
      UDG_COUNT = 21
      SHADE_TABLE_OFFSET = 152
      SHADE_COUNT = 16

      def initialize(sna:)
        @sna = sna
      end

      def extract(table)
        return nil unless table

        count = table.fetch("count").to_i
        address = table.fetch("address").to_i
        return nil unless count.positive?
        return nil unless valid_range?(address, count)

        {
          "count" => count,
          "address" => address,
          "first_char" => FIRST_CHAR,
          "bytes_per_char" => BYTES_PER_CHAR,
          "entries" => count.times.map { |index| extract_bank(address, index) },
        }
      end

      def extract_udgs
        address = sna.peek(SYSVAR_UDG).to_i | (sna.peek(SYSVAR_UDG + 1).to_i << 8)
        return nil unless valid_udg_range?(address)

        {
          "address" => address,
          "first_char" => FIRST_UDG,
          "bytes_per_char" => BYTES_PER_CHAR,
          "glyphs" => glyphs_for_range(address, FIRST_UDG, UDG_COUNT),
        }
      end

      def extract_shade_patterns(main_top)
        address = main_top.to_i + SHADE_TABLE_OFFSET
        return nil unless valid_bytes_range?(address, SHADE_COUNT * BYTES_PER_CHAR)

        {
          "address" => address,
          "first_pattern" => 0,
          "bytes_per_pattern" => BYTES_PER_CHAR,
          "patterns" => SHADE_COUNT.times.each_with_object({}) do |pattern_id, patterns|
            offset = address + pattern_id * BYTES_PER_CHAR
            patterns[pattern_id.to_s] = BYTES_PER_CHAR.times.map { |row| sna.peek(offset + row).to_i }
          end,
        }
      end

      private

      attr_reader :sna

      def valid_range?(address, count)
        address >= 16_384 && address + count * BANK_SIZE <= MEMORY_LIMIT
      end

      def valid_udg_range?(address)
        address >= 16_384 && address + UDG_COUNT * BYTES_PER_CHAR <= MEMORY_LIMIT
      end

      def valid_bytes_range?(address, byte_count)
        address >= 16_384 && address + byte_count <= MEMORY_LIMIT
      end

      def extract_bank(address, index)
        bank_address = address + index * BANK_SIZE
        {
          "id" => index + 1,
          "address" => bank_address,
          "glyphs" => glyphs_for_range(bank_address, FIRST_CHAR, CHAR_COUNT),
        }
      end

      def glyphs_for_range(bank_address, first_char, count)
        first_char.upto(first_char + count - 1).each_with_object({}) do |char_code, glyphs|
          offset = bank_address + (char_code - first_char) * BYTES_PER_CHAR
          glyphs[char_code.to_s] = BYTES_PER_CHAR.times.map { |row| sna.peek(offset + row).to_i }
        end
      end
    end
  end
end
