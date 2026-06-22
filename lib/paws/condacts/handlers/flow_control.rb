# frozen_string_literal: true

module PAWS
  module CondactHandlers
    # Registers condacts that control process execution and turn flow.
    # ProcessExecutionContext owns DONE/NOTDONE state while ProcessRunner still owns nesting.
    module FlowControl
      module_function

      def register(registry, engine, execution_context:, process_control:)
        registry.register("DONE", opcode: 22) do
          execution_context.mark_done
          :ok
        end

        registry.register("NOTDONE", opcode: 103) do
          execution_context.mark_notdone
          :ok
        end

        registry.register("OK", opcode: 23) do
          engine.output_sysmess(15)
          execution_context.mark_done
          engine.set_done
          :ok
        end

        registry.register("DESC", opcode: 19) do
          engine.log("Jumping to description phase", 2)
          engine.request_description
          throw :desc_jump
        end

        registry.register("GOTO", opcode: 37) do |loc|
          engine.state.location = loc
          :ok
        end

        registry.register("PROCESS", opcode: 75) do |process_id|
          process_control.run_subprocess(process_id)
          interface = engine.interface if engine.respond_to?(:interface)
          interface.after_process_call if interface&.respond_to?(:after_process_call)
          :ok
        end
      end
    end
  end
end
