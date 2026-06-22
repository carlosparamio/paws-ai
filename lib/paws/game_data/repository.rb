# frozen_string_literal: true

module PAWS
  module GameData
    # Read-only lookup facade over the extracted game_data hash.
    # It is the single normalization point for symbol/string keys and the place
    # where array-vs-hash collection differences are hidden from runtime code.
    # The underlying hash is intentionally shared with Engine so tests and debug
    # tools that mutate game_data still see consistent lookup results.
    class Repository
      attr_reader :data

      def self.normalize(value)
        case value
        when Hash
          value.transform_keys(&:to_s).transform_values { |child| normalize(child) }
        when Array
          value.map { |child| normalize(child) }
        else
          value
        end
      end

      def initialize(data)
        @data = self.class.normalize(data)
      end

      def [](key)
        data[key.to_s]
      end

      def dig(*keys)
        keys.reduce(data) do |current, key|
          break nil if current.nil?

          current.is_a?(Hash) ? current[key.to_s] : current[key]
        end
      end

      def to_h
        data
      end

      def item(collection_name, id)
        collection_item(self[collection_name], id)
      end

      def process(id)
        collection = self["processes"]
        return nil unless collection

        if collection.is_a?(Array)
          collection.find { |process| process["id"].to_i == id.to_i } || collection[id.to_i]
        else
          collection[id.to_s] || collection[id.to_i]
        end
      end

      def location(id)
        item("locations", id)
      end

      def message(id)
        item("messages", id)
      end

      def system_message(id)
        item("system_messages", id)
      end

      def object(id)
        item("objects", id)
      end

      def location_text(id)
        entry = location(id)
        entry.is_a?(Hash) ? entry["description"] : entry
      end

      def message_text(id)
        text_value(message(id))
      end

      def system_message_text(id)
        text_value(system_message(id))
      end

      def object_text(id)
        entry = object(id)
        return nil unless entry.is_a?(Hash)

        entry["name"] || entry["description"]
      end

      def vocabulary
        self["vocabulary"] || []
      end

      def vocabulary_entry(id, type_id = nil)
        entries = vocabulary.select { |entry| entry["id"] == id }
        entries.find { |entry| entry["type_id"] == type_id } || entries.first
      end

      def vocabulary_entry_for_word(word)
        word = word.to_s.downcase[0, 5]
        vocabulary.find { |entry| entry["word"].to_s.downcase == word }
      end

      def vocabulary_word(id, type_id)
        entry = vocabulary_entry(id, type_id)
        entry ? entry["word"].upcase : nil
      end

      private

      def collection_item(collection, id)
        return nil unless collection

        if collection.is_a?(Array)
          collection[id.to_i]
        else
          collection[id.to_s] || collection[id.to_i]
        end
      end

      def text_value(entry)
        entry.is_a?(Hash) ? entry["text"] : entry
      end
    end
  end
end
