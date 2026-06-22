# frozen_string_literal: true

require "json"

module PAWS
  module GameData
    # Decodes PAWS text stored inside Spectrum snapshot memory.
    # This object owns the byte-level text strategy used by Extractor: XOR
    # decoding, custom character mappings, PAWS control codes, and compressed
    # abbreviation expansion. Extractor remains responsible for table layout,
    # while TextDecoder handles the character stream.
    class TextDecoder
      DEFAULT_MAPPING = {
        "@" => "á", "$" => "í", "%" => "ó", "&" => "ú",
        '\\' => "ñ", "`" => "ü", "^" => "\n", "#" => "é",
        "[" => "¡", "]" => "¿", "|" => "ñ",
      }.freeze

      CONTROL_CODES = {
        16 => { name: "ink", params: 1 },
        17 => { name: "paper", params: 1 },
        18 => { name: "flash", params: 1 },
        19 => { name: "bright", params: 1 },
        20 => { name: "inverse", params: 1 },
        21 => { name: "over", params: 1 },
        22 => { name: "at", params: 2 },
        23 => { name: "tab", params: 1 },
      }.freeze

      COLOR_NAMES = %w[black blue red magenta green cyan yellow white].freeze

      def self.load_mapping(mapping_source)
        raw = if mapping_source.is_a?(Hash)
            mapping_source
          elsif mapping_source.is_a?(String) && File.exist?(mapping_source)
            JSON.parse(File.read(mapping_source))
          else
            DEFAULT_MAPPING
          end

        normalize_mapping(raw)
      end

      def self.normalize_mapping(raw)
        raw.each_with_object({}) do |(key, value), normalized|
          normalized[normalize_mapping_key(key)] = value
        end
      end

      def self.normalize_mapping_key(key)
        if key.is_a?(Integer)
          key.chr
        elsif key.to_s =~ /^\d+$/ && key.to_s.length > 1
          key.to_i.chr
        else
          key.to_s
        end
      end

      def initialize(sna:, char_mapping:, compressed:, off_abbrev:)
        @sna = sna
        @char_mapping = char_mapping
        @compressed = compressed
        @off_abbrev = off_abbrev
      end

      def read_xor_string(addr, length)
        bytes = []
        length.times do |i|
          byte = sna.peek(addr + i)
          bytes << (byte ^ 0xFF) if byte
        end
        bytes.pack("C*").strip
      end

      def expand_paws_text(addr)
        return "" unless addr && addr >= 16_384

        result = []
        ptr = addr
        safety = 0

        while safety < 5000
          raw = sna.peek(ptr)
          break unless raw

          byte = raw ^ 0xFF
          break if byte == 31

          ptr = append_decoded_byte(result, ptr, byte)
          safety += 1
        end

        result.join
      end

      def expand_abbreviation(index)
        return "" unless off_abbrev

        ptr = abbreviation_start(index)
        read_abbreviation(ptr)
      end

      def apply_mapping(text)
        return "" if text.nil?

        text.chars.map { |char| mapped_char(char.ord, char) }.join
      end

      private

      attr_reader :sna, :char_mapping, :compressed, :off_abbrev

      def append_decoded_byte(result, ptr, byte)
        if compressed && byte >= 164 && byte <= 254
          result << expand_abbreviation(byte - 164)
          ptr + 1
        elsif byte >= 32 && byte <= 128
          append_printable_byte(result, byte)
          ptr + 1
        elsif [13, 7].include?(byte)
          result << "\n"
          ptr + 1
        elsif CONTROL_CODES.key?(byte)
          append_control_code(result, ptr, byte)
        elsif byte < 32
          result << "{#{byte}}"
          ptr + 1
        else
          ptr + 1
        end
      end

      def append_printable_byte(result, byte)
        if byte == 128
          result << " "
        else
          char = byte.chr
          result << mapped_char(byte, char)
        end
      end

      def append_control_code(result, ptr, byte)
        code_def = CONTROL_CODES[byte]
        params = []
        code_def[:params].times do |i|
          raw_param = sna.peek(ptr + 1 + i)
          param = raw_param ? (raw_param ^ 0xFF) : 0
          params << control_param(byte, param)
        end
        result << "{#{code_def[:name]}:#{params.join(",")}}"
        ptr + 1 + code_def[:params]
      end

      def control_param(byte, param)
        if [16, 17].include?(byte) && param < 8
          COLOR_NAMES[param]
        else
          param.to_s
        end
      end

      def abbreviation_start(index)
        ptr = off_abbrev
        index.times do
          safety = 0
          loop do
            byte = sna.peek(ptr)
            ptr += 1
            break if (byte && (byte & 0x80) != 0) || safety > 1000

            safety += 1
          end
        end
        ptr
      end

      def read_abbreviation(ptr)
        result = []
        safety = 0
        loop do
          byte = sna.peek(ptr)
          break unless byte

          ptr += 1
          char_code = byte & 0x7F
          terminated = (byte & 0x80) != 0

          if CONTROL_CODES.key?(char_code)
            control = CONTROL_CODES.fetch(char_code)
            params = []
            control[:params].times do
              raw_param = sna.peek(ptr)
              param = raw_param ? (raw_param & 0x7F) : 0
              params << control_param(char_code, param)
              terminated ||= raw_param && (raw_param & 0x80) != 0
              ptr += 1
            end
            result << "{#{control[:name]}:#{params.join(",")}}"
          else
            append_abbreviation_char(result, char_code)
          end

          break if terminated || safety > 1000

          safety += 1
        end
        result.join
      end

      def append_abbreviation_char(result, char_code)
        return unless char_code >= 32 && char_code < 127

        char = char_code.chr
        result << mapped_char(char_code, char)
      end

      def mapped_char(byte, char)
        mapped = char_mapping[char]
        return char unless mapped
        return mapped if mapped.start_with?("{glyph:")
        return mapped if mapped.ascii_only?

        "{glyph:#{byte}:#{mapped}}"
      end
    end
  end
end
