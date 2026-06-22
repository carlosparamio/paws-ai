# frozen_string_literal: true

module PAWS
  # Runs the PAWS response phase from flowchart 1.
  # The player phrase has already been parsed and stored in the logical sentence
  # flags. This phase advances the turn counter, clears DONE, executes process 0
  # in response mode, and then delegates to MovementFallback only if the process
  # table did not handle the command itself.
  class ResponsePhase
    def initialize(engine)
      @engine = engine
    end

    def call
      engine.state.increment_turns
      engine.done_flag = false
      engine.run_process(0, mode: :response)

      engine.fallback_response unless engine.done_flag || !engine.running?
    end

    private

    attr_reader :engine
  end
end
