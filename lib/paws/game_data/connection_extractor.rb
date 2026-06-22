# frozen_string_literal: true

module PAWS
  module GameData
    # Extracts movement connection tables from PAWS snapshot memory.
    # Each location points to a list of direction/destination byte pairs
    # terminated by 255. The output intentionally stays as `[loc, pairs]` arrays
    # because that is the current serializer/contract format.
    class ConnectionExtractor
      TERMINATOR = 255

      def initialize(sna:)
        @sna = sna
      end

      def extract(offset, location_count)
        connections = []

        location_count.times do |loc|
          loc_connections = extract_location_connections(sna.peek_word(offset + loc * 2))
          connections << [loc, loc_connections] unless loc_connections.empty?
        end

        connections
      end

      private

      attr_reader :sna

      def extract_location_connections(pointer)
        return [] unless pointer

        loc_connections = []
        safety = 0
        while sna.peek(pointer) != TERMINATOR && safety < 100
          loc_connections << [sna.peek(pointer), sna.peek(pointer + 1)]
          pointer += 2
          safety += 1
        end
        loc_connections
      end
    end
  end
end
