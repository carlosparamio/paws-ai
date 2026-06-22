# frozen_string_literal: true

require_relative "../game_state"
require_relative "../process_runner"

module PAWS
  # Runs the PAWS description phase from flowchart 1.
  # This Phase Object owns the exact order for refreshing the current location:
  # clear the screen when F40 allows it, decrement description timers F2/F3/F4,
  # emit either darkness or location text, then run process 1 with wildcard
  # verb/noun flags so the game can list objects or print local event text.
  #
  # Engine remains the Application Service and public facade; DescriptionPhase
  # is deliberately narrow and delegates output/repository details back through
  # Engine's existing ports.
  class DescriptionPhase
    def initialize(engine)
      @engine = engine
    end

    def call
      engine.describe_flag = false
      engine.done_flag = false

      describe_location
      return unless engine.running?

      state.set_flag(GameState::FLAG_VERB, ProcessRunner::WILDCARD_STAR)
      state.set_flag(GameState::FLAG_NOUN1, ProcessRunner::WILDCARD_STAR)
      engine.run_process(1, mode: :automatic)
    end

    def describe_location
      loc = state.location
      return if loc.zero?

      maybe_clear_screen
      decrement_description_flags
      output_description_text(loc)
    end

    private

    attr_reader :engine

    def state
      engine.state
    end

    def maybe_clear_screen
      engine.log("🖥️ describe_location: #{engine.interface.fmt_flag(40)}=#{engine.interface.fmt_val(state.get_flag(GameState::FLAG_SCREEN_MODE))}, skip_clear_screen=#{engine.interface.fmt_val(engine.skip_clear_screen)}", 2)
      return unless state.get_flag(GameState::FLAG_SCREEN_MODE).even?
      return if engine.skip_clear_screen

      engine.interface.clear_screen
    end

    def decrement_description_flags
      engine.decrement_flag(2)
      return unless state.dark?

      engine.decrement_flag(3)
      engine.decrement_flag(4) unless state.object_present?(0)
    end

    def output_description_text(loc)
      if state.dark?
        engine.output_sysmess(8, newline: true)
      else
        engine.output_location_text(loc, newline: false)
      end
    end
  end
end
