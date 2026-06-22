# frozen_string_literal: true

require_relative "../game_state"

module PAWS
  # Handles the direction branch at the end of PAWS flowchart 1.
  # Process 0 gets the first chance to handle the player's logical sentence; if
  # it does not mark the turn as DONE, PAWS falls back to built-in movement for
  # direction verbs and emits the standard "you cannot go that way" or "I do not
  # understand" system messages.
  #
  # This is a small Phase Object extracted from Engine. It keeps the turn-flow
  # rule close to its PAWS semantics while Engine remains the application
  # coordinator for parser, process execution, and UI phases.
  class MovementFallback
    DIRECTION_VERBS = 0...14

    def initialize(engine)
      @engine = engine
    end

    def fallback_response
      verb = state.get_flag(GameState::FLAG_VERB)

      return invalid_verb unless direction?(verb)

      move_or_fail_with_message(verb)
    end

    def try_direction_movement
      verb = state.get_flag(GameState::FLAG_VERB)

      return :failed unless direction?(verb)

      dest = state.connection(state.location, verb)
      return :failed unless dest

      state.location = dest
      engine.describe_flag = true
      :moved
    end

    private

    attr_reader :engine

    def state
      engine.state
    end

    def direction?(verb)
      DIRECTION_VERBS.cover?(verb)
    end

    def move_or_fail_with_message(verb)
      dest = state.connection(state.location, verb)

      if dest
        state.location = dest
        engine.describe_flag = true
        engine.done_flag = true
        :moved
      else
        engine.output_sysmess(7, newline: true)
        engine.done_flag = true
        :failed
      end
    end

    def invalid_verb
      engine.output_sysmess(8, newline: true)
      engine.done_flag = true
      :failed
    end
  end
end
