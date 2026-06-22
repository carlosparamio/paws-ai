# frozen_string_literal: true

module PAWS
  module CondactHandlers
    # Registers save/load and game-ending condacts.
    # User prompts go through the runtime interface; DONE bookkeeping lives in
    # ProcessExecutionContext.
    module Persistence
      module_function

      def register(registry, engine, execution_context:)
        registry.register("RAMSAVE", opcode: 62) do
          engine.state.ramsave
          :ok
        end

        registry.register("RAMLOAD", opcode: 63) do |flag_limit|
          engine.state.ramload(flag_limit) ? :ok : :failed
        end

        registry.register("SAVE", opcode: 25) do
          engine.interface.save_game(engine.state)
          :ok
        end

        registry.register("LOAD", opcode: 26) do
          if engine.interface.load_game(engine)
            :ok
          else
            engine.output_sysmess(54, newline: true)
            registry.call("ANYKEY")
            registry.call("DESC")
          end
        end

        registry.register("END", opcode: 21) do
          engine.output_sysmess(13)
          key = engine.interface.wait_for_key("")

          if pending_key?(engine.interface, key)
            engine.interface.pending_end_confirmation = true if engine.interface.respond_to?(:pending_end_confirmation=)
            execution_context.mark_done
            next :abort
          end

          if accepted_key?(engine, key)
            engine.restart
          else
            engine.stop
          end

          execution_context.mark_done
          :abort
        end

        registry.register("QUIT", opcode: 20) do
          engine.output_sysmess(12)
          key = engine.interface.wait_for_key("")

          if pending_key?(engine.interface, key)
            engine.interface.pending_quit_confirmation = true if engine.interface.respond_to?(:pending_quit_confirmation=)
            next :abort
          end

          if accepted_key?(engine, key)
            engine.stop
            :ok
          else
            execution_context.mark_done
            :failed
          end
        end
      end

      def accepted_key?(engine, key)
        key.to_s.downcase == accepted_key(engine).to_s.downcase
      end

      def pending_key?(interface, key)
        interface.respond_to?(:pending_key?) && interface.pending_key?(key)
      end

      def accepted_key(engine)
        sm30 = engine.game_data.dig("system_messages", 30)
        if sm30.is_a?(Hash)
          sm30["text"]&.chars&.first
        else
          sm30&.to_s&.chars&.first
        end || "s"
      end
    end
  end
end
