# frozen_string_literal: true

module PAWS
  module GameData
    # Extracts the PAWS abbreviation table when text compression is active.
    # TextDecoder owns the byte-level expansion algorithm; this reader only
    # applies the official PAWS code range used by serialized game data.
    class AbbreviationExtractor
      FIRST_CODE = 164
      COUNT = 91

      def initialize(text_decoder:)
        @text_decoder = text_decoder
      end

      def extract
        Array.new(COUNT) do |index|
          { "code" => FIRST_CODE + index, "text" => text_decoder.expand_abbreviation(index) }
        end
      end

      private

      attr_reader :text_decoder
    end
  end
end
