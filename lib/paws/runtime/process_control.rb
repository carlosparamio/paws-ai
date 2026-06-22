# frozen_string_literal: true

module PAWS
  # Public orchestration API exposed to condact handlers.
  # It keeps handlers from depending on ProcessRunner internals while still
  # letting process-oriented condacts trigger nested process execution.
  #
  # This is a small Facade over the runner. Handlers receive only the operations
  # they need (run another process, continue a condact list, ask whether the
  # current call started from response process 0) instead of the full runner.
  class ProcessControl
    def initialize(runner)
      @runner = runner
    end

    def run_process(process_id)
      runner.run_process(process_id)
    end

    def run_subprocess(process_id)
      runner.run_process(process_id, mode: :automatic)
    end

    def run_condacts(condacts)
      runner.run_condacts(condacts)
    end

    def response_process?
      runner.process_stack.first == 0
    end

    private

    attr_reader :runner
  end
end
