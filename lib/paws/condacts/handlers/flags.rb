# frozen_string_literal: true

module PAWS
  module CondactHandlers
    # Registers flag-related condacts and conditions.
    # This is the first migrated handler family; ProcessRunner still owns dispatch and control flow.
    module Flags
      module_function

      def register(registry, engine)
        register_flag_conditions(registry, engine)
        register_flag_actions(registry, engine)
      end

      def register_flag_conditions(registry, engine)
        registry.register("ZERO", opcode: 11) do |flag|
          flag_value(engine, flag).zero? ? :ok : :failed
        end

        registry.register("NOTZERO", opcode: 12) do |flag|
          flag_value(engine, flag).zero? ? :failed : :ok
        end

        registry.register("EQ", opcode: 13) do |flag, value|
          compare_flag(engine, flag, :==, value)
        end

        registry.register("GT", opcode: 14) do |flag, value|
          compare_flag(engine, flag, :>, value)
        end

        registry.register("LT", opcode: 15) do |flag, value|
          compare_flag(engine, flag, :<, value)
        end

        registry.register("SAME", opcode: 76) do |flag1, flag2|
          compare_flags(engine, flag1, :==, flag2)
        end

        registry.register("NOTEQ", opcode: 79) do |flag, value|
          compare_flag(engine, flag, :!=, value)
        end

        registry.register("NOTSAME", opcode: 80) do |flag1, flag2|
          compare_flags(engine, flag1, :!=, flag2)
        end

        registry.register("BIGGER") do |flag1, flag2|
          compare_flags(engine, flag1, :>, flag2)
        end

        registry.register("SMALLER") do |flag1, flag2|
          compare_flags(engine, flag1, :<, flag2)
        end
      end

      def register_flag_actions(registry, engine)
        registry.register("SET", opcode: 47) do |flag|
          set_flag(engine, flag, 255)
        end

        registry.register("CLEAR", opcode: 48) do |flag|
          set_flag(engine, flag, 0)
        end

        registry.register("PLUS", opcode: 49) do |flag, value|
          set_flag(engine, flag, flag_value(engine, flag) + value)
        end

        registry.register("MINUS", opcode: 50) do |flag, value|
          set_flag(engine, flag, [flag_value(engine, flag) - value, 0].max)
        end

        registry.register("LET", opcode: 51) do |flag, value|
          set_flag(engine, flag, value)
        end

        registry.register("COPYFF", opcode: 59) do |flag1, flag2|
          set_flag(engine, flag2, flag_value(engine, flag1))
        end
      end

      def compare_flag(engine, flag, operator, expected)
        flag_value(engine, flag).public_send(operator, expected) ? :ok : :failed
      end

      def compare_flags(engine, flag1, operator, flag2)
        flag_value(engine, flag1).public_send(operator, flag_value(engine, flag2)) ? :ok : :failed
      end

      def flag_value(engine, flag)
        state_for(engine).get_flag(flag)
      end

      def set_flag(engine, flag, value)
        state_for(engine).set_flag(flag, value)
        :ok
      end

      def state_for(engine)
        engine.state || raise("Engine state is not initialized")
      end
    end
  end
end
