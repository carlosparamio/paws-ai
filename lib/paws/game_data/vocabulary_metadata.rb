# frozen_string_literal: true

module PAWS
  module GameData
    # Snapshot metadata used by the extractor to label PAWS vocabulary entries.
    module VocabularyMetadata
      TYPES = {
        0 => "verb",
        1 => "adverb",
        2 => "noun",
        3 => "adjective",
        4 => "preposition",
        5 => "conjunction",
        6 => "pronoun",
        7 => "reserved",
      }.freeze

      module_function

      def type_name(type_id)
        TYPES[type_id] || "unknown"
      end
    end
  end
end
