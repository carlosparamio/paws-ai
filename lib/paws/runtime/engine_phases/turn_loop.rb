# frozen_string_literal: true

module PAWS
  # Coordinates the PAWS turn loop from flowchart 1.
  # This Phase Object keeps the high-level ordering in one place while the
  # detailed work remains delegated to DescriptionPhase, InputPhase, and
  # ResponsePhase. Engine intentionally keeps public wrapper methods around this
  # object so tests, harnesses, and debugger-adjacent code can continue to drive
  # individual phases without knowing the internal class layout.
  class TurnLoop
    def initialize(engine)
      @engine = engine
    end

    def call
      catch :desc_jump do
        if engine.describe_flag
          engine.description_phase
          return if engine.consume_restart_request
          return unless engine.running?
        end

        engine.order_loop
      end
    end

    def order_loop
      engine.done_flag = false
      engine.run_process(2, mode: :automatic)
      return if engine.consume_restart_request
      return unless engine.running?

      if engine.describe_flag
        engine.description_phase
        return if engine.consume_restart_request
        return unless engine.running?
      end

      result = engine.input_phase
      return unless engine.running?

      case result
      when :timeout
        engine.output_sysmess(35, newline: true)
      when :not_found
        engine.output_sysmess(6, newline: true)
      else
        engine.response_phase
      end
    end

    private

    attr_reader :engine
  end
end
