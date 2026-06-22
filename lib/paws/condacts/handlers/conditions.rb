# frozen_string_literal: true

require_relative "../../runtime/game_state"
require_relative "../../runtime/execution_result"
require_relative "../../runtime/location_ref"

module PAWS
  module CondactHandlers
    # Registers world, parser-word, timeout, and chance condition condacts.
    # These handlers inspect GameState and return normalized condition results without owning process flow.
    module Conditions
      module_function

      def register(registry, engine, random:)
        register_location_conditions(registry, engine)
        register_object_conditions(registry, engine)
        register_parser_word_conditions(registry, engine)
        register_runtime_conditions(registry, engine, random: random)
      end

      def register_location_conditions(registry, engine)
        registry.register("AT", opcode: 0) do |loc|
          compare_location(engine, loc, :==)
        end

        registry.register("NOTAT", opcode: 1) do |loc|
          compare_location(engine, loc, :!=)
        end

        registry.register("ATGT", opcode: 2) do |loc|
          compare_location(engine, loc, :>)
        end

        registry.register("ATLT", opcode: 3) do |loc|
          compare_location(engine, loc, :<)
        end
      end

      def register_object_conditions(registry, engine)
        registry.register("PRESENT", opcode: 4) do |objno|
          object_predicate(engine, objno, :object_present?)
        end

        registry.register("ABSENT", opcode: 5) do |objno|
          object_predicate(engine, objno, :object_absent?)
        end

        registry.register("WORN", opcode: 6) do |objno|
          object_predicate(engine, objno, :object_worn?)
        end

        registry.register("NOTWORN", opcode: 7) do |objno|
          negative_object_predicate(engine, objno, :object_worn?)
        end

        registry.register("CARRIED", opcode: 8) do |objno|
          object_predicate(engine, objno, :object_carried?)
        end

        registry.register("NOTCARR", opcode: 9) do |objno|
          negative_object_predicate(engine, objno, :object_carried?)
        end

        registry.register("ISAT", opcode: 55) do |objno, loc|
          object_location(engine, objno, loc, :==)
        end

        registry.register("ISNOTAT", opcode: 88) do |objno, loc|
          object_location(engine, objno, loc, :!=)
        end
      end

      def register_parser_word_conditions(registry, engine)
        registry.register("ADJECT1", opcode: 16) do |adj|
          flag_equals(engine, GameState::FLAG_ADJECT1, adj)
        end

        registry.register("ADVERB", opcode: 17) do |adv|
          flag_equals(engine, GameState::FLAG_ADVERB, adv)
        end

        registry.register("PREP", opcode: 68) do |prep|
          flag_equals(engine, GameState::FLAG_PREP, prep)
        end

        registry.register("NOUN2", opcode: 69) do |noun|
          flag_equals(engine, GameState::FLAG_NOUN2, noun)
        end

        registry.register("ADJECT2", opcode: 70) do |adj|
          flag_equals(engine, GameState::FLAG_ADJECT2, adj)
        end
      end

      def register_runtime_conditions(registry, engine, random:)
        registry.register("CHANCE", opcode: 10) do |percent|
          chance(percent, random: random)
        end

        registry.register("TIMEOUT", opcode: 36) do
          timeout(engine)
        end
      end

      def compare_location(engine, loc, operator)
        actual = engine.state.location
        expected = resolve_loc(engine, loc)

        actual.public_send(operator, expected) ? ExecutionResult.ok : ExecutionResult.failed("at location #{actual}")
      end

      def object_predicate(engine, objno, predicate)
        loc = engine.state.object_at(objno)

        engine.state.public_send(predicate, objno) ? ExecutionResult.ok : ExecutionResult.failed("object #{objno} is at #{loc}")
      end

      def negative_object_predicate(engine, objno, predicate)
        loc = engine.state.object_at(objno)

        !engine.state.public_send(predicate, objno) ? ExecutionResult.ok : ExecutionResult.failed("object #{objno} is at #{loc}")
      end

      def object_location(engine, objno, loc, operator)
        actual = engine.state.object_at(objno)
        expected = resolve_loc(engine, loc)

        actual.public_send(operator, expected) ? ExecutionResult.ok : ExecutionResult.failed("object #{objno} is at #{actual}")
      end

      def flag_equals(engine, flag, expected)
        actual = engine.state.get_flag(flag)

        actual == expected ? ExecutionResult.ok : ExecutionResult.failed("actual value is #{actual}")
      end

      def timeout(engine)
        actual = engine.state.get_flag(GameState::FLAG_TIMEOUT_FLAGS)

        (actual & 0x80) != 0 ? ExecutionResult.ok : ExecutionResult.failed("timeout flag is #{actual}")
      end

      def chance(percent, random:)
        value = random.call(1..100)

        value <= percent ? ExecutionResult.ok : ExecutionResult.failed("rolled #{value}")
      end

      def resolve_loc(engine, loc)
        LocationRef.parse(loc).resolve(current_location: engine.state.location)
      end
    end
  end
end
