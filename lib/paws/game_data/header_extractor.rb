# frozen_string_literal: true

module PAWS
  module GameData
    # Extracts PAWS header metadata and display defaults from snapshot memory.
    # The top-level Extractor uses this as a structural reader: it validates the
    # PAWS main area, identifies whether compression/abbreviations are active,
    # and exposes the counts needed by later table readers.
    class HeaderExtractor
      ADDR_MAIN_TOP = 65_533
      ADDR_PAW_VERSION = 65_527
      MAIN_TOP_RANGE = 16_385...65_000
      MAIN_ATTR_OFFSET = 311
      CHARSET_COUNT_OFFSET = 329
      CHARSET_TABLE_OFFSET = 330
      ABBREVIATION_OFFSET = 332
      DEFAULTS_CHARSET_OFFSET = 281
      SIGNATURE_BYTES = [16, 17, 18, 19, 20, 21].freeze

      Header = Struct.new(
        :main_top,
        :version,
        :paw_version,
        :compressed,
        :off_abbrev,
        keyword_init: true,
      )

      def initialize(sna:)
        @sna = sna
      end

      def detect
        main_top = sna.peek_word(ADDR_MAIN_TOP)
        raise "Invalid PAWS game: MainTop out of range" unless MAIN_TOP_RANGE.cover?(main_top)

        return unknown_header(main_top) unless paws_signature?(main_top)

        off_abbrev = sna.peek_word(main_top + ABBREVIATION_OFFSET)
        Header.new(
          main_top: main_top,
          version: :paws,
          paw_version: sna.peek(ADDR_PAW_VERSION),
          compressed: off_abbrev && sna.peek(off_abbrev) != 255,
          off_abbrev: off_abbrev,
        )
      end

      def game_info(header)
        {
          "version" => header.version.to_s,
          "paw_version" => header.paw_version,
          "compressed" => header.compressed,
          "num_locations" => sna.peek(header.main_top + 325),
          "num_messages" => sna.peek(header.main_top + 326),
          "num_system_messages" => sna.peek(header.main_top + 327),
          "num_objects" => sna.peek(header.main_top + 324),
          "num_processes" => sna.peek(header.main_top + 328),
        }
      end

      def defaults(header)
        return nil unless header.version == :paws

        main_attr = header.main_top + MAIN_ATTR_OFFSET
        {
          "charset" => sna.peek(header.main_top + DEFAULTS_CHARSET_OFFSET),
          "ink" => sna.peek(main_attr + 1),
          "paper" => sna.peek(main_attr + 3),
          "flash" => sna.peek(main_attr + 5),
          "bright" => sna.peek(main_attr + 7),
          "inverse" => sna.peek(main_attr + 9),
          "over" => sna.peek(main_attr + 11),
          "border" => sna.peek(main_attr + 12),
        }
      end

      def charset_table(header)
        return nil unless header.version == :paws

        count = sna.peek(header.main_top + CHARSET_COUNT_OFFSET).to_i
        address = sna.peek_word(header.main_top + CHARSET_TABLE_OFFSET)
        return nil unless count.positive? && address && address >= 16_384

        {
          "count" => count,
          "address" => address,
        }
      end

      private

      attr_reader :sna

      def unknown_header(main_top)
        Header.new(
          main_top: main_top,
          version: :unknown,
          paw_version: nil,
          compressed: false,
          off_abbrev: nil,
        )
      end

      def paws_signature?(main_top)
        main_attr = main_top + MAIN_ATTR_OFFSET
        SIGNATURE_BYTES.each_with_index.all? do |expected, index|
          sna.peek(main_attr + index * 2) == expected
        end
      end
    end
  end
end
