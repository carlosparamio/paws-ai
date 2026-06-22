# frozen_string_literal: true

require_relative "../runtime/execution_result"

module PAWS
  # Dispatch table for condact handlers.
  # The registry maps both canonical condact names and extracted opcodes to
  # callable handler blocks. ProcessRunner uses it as the runtime dispatch point,
  # while the extractor can still rely on metadata for arity and names.
  #
  # This is the core extension point for condact families: adding a handler group
  # should register behavior here instead of adding another branch to
  # ProcessRunner.
  class CondactRegistry
    def initialize
      @handlers_by_name = {}
      @handlers_by_opcode = {}
    end

    def register(name, opcode: nil, &handler)
      raise ArgumentError, "handler block is required" unless handler

      canonical_name = normalize_name(name)
      @handlers_by_name[canonical_name] = handler
      @handlers_by_opcode[Integer(opcode)] = handler if opcode
      self
    end

    def registered?(name_or_opcode)
      !handler_for(name_or_opcode).nil?
    end

    def call(name_or_opcode, params = [])
      handler = handler_for(name_or_opcode)
      raise KeyError, "Unknown condact: #{name_or_opcode}" unless handler

      ExecutionResult.from(handler.call(*params))
    end

    private

    def handler_for(name_or_opcode)
      if name_or_opcode.is_a?(Integer)
        @handlers_by_opcode[name_or_opcode]
      else
        @handlers_by_name[normalize_name(name_or_opcode)]
      end
    end

    def normalize_name(name)
      name.to_s.upcase
    end
  end
end
