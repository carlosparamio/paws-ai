# frozen_string_literal: true

module PAWS
  module GameData
    # Extracts PAWS pointer tables whose entries reference encoded text.
    # Locations, user messages, and system messages all share this table shape:
    # a sequence of 16-bit pointers followed by PAWS-compressed/XOR text owned by
    # TextDecoder.
    class TextTableExtractor
      def initialize(sna:, text_decoder:)
        @sna = sna
        @text_decoder = text_decoder
      end

      def extract_messages(offset, count)
        extract_texts(offset, count)
      end

      def extract_locations(offset, count)
        extract_texts(offset, count).each_with_index.map do |text, index|
          { "id" => index, "description" => text }
        end
      end

      private

      attr_reader :sna, :text_decoder

      def extract_texts(offset, count)
        Array.new(count) do |index|
          text_ptr = sna.peek_word(offset + index * 2)
          text_ptr ? text_decoder.expand_paws_text(text_ptr) || "" : ""
        end
      end
    end
  end
end
