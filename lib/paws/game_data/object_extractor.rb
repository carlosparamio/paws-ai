# frozen_string_literal: true

require_relative "../runtime/location_ref"

module PAWS
  module GameData
    # Extracts object definitions from the PAWS object tables.
    # PAWS stores object data across several parallel tables: names, initial
    # locations, vocabulary ids, and packed weight/attribute bytes. This reader
    # keeps that binary layout in one place and returns normalized object hashes.
    class ObjectExtractor
      def initialize(sna:, text_decoder:)
        @sna = sna
        @text_decoder = text_decoder
      end

      def extract(count:, name_offset:, location_offset:, word_offset:, extra_offset:)
        Array.new(count) do |index|
          object = { "id" => index }
          add_name(object, index, name_offset)
          add_initial_location(object, index, location_offset)
          add_vocabulary_ids(object, index, word_offset)
          add_extra_attributes(object, index, extra_offset)
          object
        end
      end

      private

      attr_reader :sna, :text_decoder

      def add_name(object, index, offset)
        return unless offset

        name_ptr = sna.peek_word(offset + index * 2)
        object["name"] = text_decoder.expand_paws_text(name_ptr) if name_ptr
      end

      def add_initial_location(object, index, offset)
        return unless offset

        location = sna.peek(offset + index)
        object["initial_location"] = location
        object["initial_location_name"] = LocationRef.object_location_name(location)&.to_s
      end

      def add_vocabulary_ids(object, index, offset)
        return unless offset

        object["noun_id"] = sna.peek(offset + index * 2)
        object["adjective_id"] = sna.peek(offset + index * 2 + 1)
      end

      def add_extra_attributes(object, index, offset)
        return unless offset

        byte = sna.peek(offset + index)
        object["weight"] = byte & 0x3F
        object["is_container"] = (byte & 0x40) != 0
        object["is_wearable"] = (byte & 0x80) != 0
      end
    end
  end
end
