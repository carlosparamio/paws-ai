# frozen_string_literal: true

require_relative "vocabulary_metadata"

module PAWS
  module GameData
    # Extracts the PAWS vocabulary table from snapshot memory.
    # This table reader owns the fixed 7-byte vocabulary entry layout while the
    # top-level Extractor decides where the table starts and how the resulting
    # array is stored in the normalized game data hash.
    class VocabularyExtractor
      ENTRY_SIZE = 7
      WORD_SIZE = 5
      TERMINATOR = 0
      DEFAULT_LIMIT = 65_509

      def initialize(sna:, text_decoder:)
        @sna = sna
        @text_decoder = text_decoder
      end

      def extract(offset, limit: DEFAULT_LIMIT)
        vocab = []
        ptr = offset
        safety = 0

        while sna.peek(ptr) != TERMINATOR && ptr < limit && safety < 1000
          type_id = sna.peek(ptr + 6)
          vocab << {
            "word" => text_decoder.apply_mapping(text_decoder.read_xor_string(ptr, WORD_SIZE)),
            "id" => sna.peek(ptr + 5),
            "type" => VocabularyMetadata.type_name(type_id),
            "type_id" => type_id,
          }
          ptr += ENTRY_SIZE
          safety += 1
        end

        vocab
      end

      private

      attr_reader :sna, :text_decoder
    end
  end
end
