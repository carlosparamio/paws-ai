# frozen_string_literal: true

require_relative "../../runtime/game_state"
require_relative "../../runtime/execution_result"

module PAWS
  module CondactHandlers
    # Registers condacts that mutate simple runtime state without owning process flow.
    # Object-specific side effects stay in ProcessRunner until the object handler slice.
    module RuntimeState
      module_function

      def register(registry, engine, random:)
        saved_location = nil

        register_arithmetic(registry, engine, random: random)
        register_capability_flags(registry, engine)
        register_location_state(registry, engine, saved_location_ref: -> { saved_location }, save_location: ->(loc) { saved_location = loc })
        register_input_and_text_state(registry, engine)
      end

      def register_arithmetic(registry, engine, random:)
        registry.register("ADD", opcode: 71) do |flag1, flag2|
          set_flag(engine, flag1, flag_value(engine, flag1) + flag_value(engine, flag2))
        end

        registry.register("SUB", opcode: 72) do |flag1, flag2|
          set_flag(engine, flag1, [flag_value(engine, flag1) - flag_value(engine, flag2), 0].max)
        end

        registry.register("RANDOM", opcode: 95) do |flag, limit = 255|
          max = limit == 0 ? 255 : limit
          set_flag(engine, flag, random.call(max + 1))
        end
      end

      def register_capability_flags(registry, engine)
        registry.register("ABILITY", opcode: 93) do |max_carried, max_weight|
          set_flag(engine, GameState::FLAG_MAX_CARRIED, max_carried)
          set_flag(engine, GameState::FLAG_MAX_WEIGHT, max_weight)
        end

        registry.register("WEIGHT", opcode: 94) do |flag|
          set_flag(engine, flag, engine.state.total_carried_weight)
        end

        registry.register("TIME", opcode: 83) do |duration, flags|
          set_flag(engine, GameState::FLAG_TIMEOUT_LENGTH, duration)
          set_flag(engine, GameState::FLAG_TIMEOUT_FLAGS, flags)
        end
      end

      def register_location_state(registry, engine, saved_location_ref:, save_location:)
        registry.register("MOVE", opcode: 106) do |direction|
          move(engine, direction)
        end

        registry.register("SAVEAT", opcode: 97) do
          save_location.call(engine.state.location)
          :ok
        end

        registry.register("BACKAT", opcode: 98) do
          saved_location = saved_location_ref.call
          engine.state.location = saved_location if saved_location
          :ok
        end
      end

      def register_input_and_text_state(registry, engine)
        registry.register("INPUT", opcode: 96) do |flag|
          input = engine.interface.get_input
          set_flag(engine, flag, input.to_i & 0xFF)
        end

        registry.register("NEWTEXT", opcode: 92) do
          engine.clear_phrases
          :ok
        end

        registry.register("RESET_FLAG") do |flag|
          set_flag(engine, flag, 0)
        end
      end

      def move(engine, direction)
        destination = engine.state.connection(engine.state.location, direction)
        return ExecutionResult.failed("no connection") unless destination

        engine.state.location = destination
        :ok
      end

      def flag_value(engine, flag)
        engine.state.get_flag(flag)
      end

      def set_flag(engine, flag, value)
        engine.state.set_flag(flag, value)
        :ok
      end
    end
  end
end
