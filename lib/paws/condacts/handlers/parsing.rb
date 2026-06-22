# frozen_string_literal: true

module PAWS
  module CondactHandlers
    # Registers parser-related condacts that ask Engine to reparse buffered input.
    module Parsing
      module_function

      def register(registry, engine)
        registry.register("PARSE", opcode: 73) do
          parse_buffer(engine)
        end
      end

      def parse_buffer(engine)
        return :ok if engine.quoted_buffer.nil? || engine.quoted_buffer.empty?

        buffer = engine.quoted_buffer
        engine.clear_parsed_state
        engine.parse_input(buffer, is_nested: true)
        engine.store_parsed_words
        engine.log_parser_result

        :continue_scan
      end
    end
  end
end
