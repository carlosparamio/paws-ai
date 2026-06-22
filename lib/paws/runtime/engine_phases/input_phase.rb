# frozen_string_literal: true

module PAWS
  # Runs the PAWS input phase from flowchart 1.
  # This Phase Object owns the turn input workflow while Engine keeps the
  # mutable parser state and phrase queue used by legacy tests and condacts such
  # as NEWTEXT. The phase decrements per-input timers, reads player input with
  # PAWS timeouts/prompts, expands one physical line into queued logical
  # phrases, and delegates the actual vocabulary parsing back to Engine.
  class InputPhase
    PHRASE_SPLIT_PATTERN = /[\.]|\s+[ye]\s+|\s+and\s+/i
    TIMEOUT_INTERVAL_SECONDS = 1.28
    TIMEOUT_OCCURRED_BIT = 0x80
    TIMEOUT_INPUT_FIRST_CHAR_BIT = 0x01
    TIMEOUT_CONTROL_MASK = 0x7F

    def initialize(engine)
      @engine = engine
    end

    def call
      decrement_input_flags
      engine.clear_parsed_state

      availability = ensure_phrase_available
      return availability unless availability == :ready
      return :timeout if phrase_queue.empty?

      process_current_phrase
    end

    def clear_phrases
      phrase_queue.clear
    end

    private

    attr_reader :engine

    def decrement_input_flags
      (5..8).each { |flag| engine.decrement_flag(flag) }
      return unless engine.state.dark?

      engine.decrement_flag(9)
      engine.decrement_flag(10) unless engine.state.object_present?(0)
    end

    def ensure_phrase_available
      loop do
        return :ready unless phrase_queue.empty?

        input = read_input
        if debug_request?(input)
          handle_debug_request
          next
        end

        log_input(input)
        engine.record_history("> #{input}") if input.is_a?(String)
        engine.capture_state_snapshot(input) if input.is_a?(String)
        if input == :timeout
          mark_timeout_occurred
          return :timeout
        end
        return engine.stop if input.nil?

        clear_timeout_occurred
        engine.replace_phrase_queue(split_phrases(input))
        reset_line_verb
      end
    end

    def read_input
      engine.interface.get_player_input(timeout: timeout_seconds, prompt: engine.get_prompt_text)
    end

    def timeout_seconds
      timeout_length = engine.state.get_flag(GameState::FLAG_TIMEOUT_LENGTH)
      timeout_flags = engine.state.get_flag(GameState::FLAG_TIMEOUT_FLAGS)
      return nil unless timeout_length.positive?
      return nil if (timeout_flags & TIMEOUT_INPUT_FIRST_CHAR_BIT).zero?
      return nil unless engine.interface.input_buffer_empty?

      timeout_length * TIMEOUT_INTERVAL_SECONDS
    end

    def debug_request?(input)
      input.is_a?(String) && input.strip.downcase == "!debug" && engine.debug_enabled?
    end

    def handle_debug_request
      engine.interface.output_text("\n🛑 Debug mode requested via '!debug'")
      engine.breakpoint_reached(
        engine.runner.current_pid,
        engine.runner.current_b_idx,
        engine.runner.current_c_idx,
        reason: "Manual request",
      )
    end

    def log_input(input)
      return if input.nil? || input == :timeout

      engine.log("⌨️ Input received: #{engine.interface.fmt_word(input)}", 2)
    end

    def split_phrases(input)
      input.split(PHRASE_SPLIT_PATTERN).map(&:strip).reject(&:empty?)
    end

    def reset_line_verb
      # The previous turn's verb must not contaminate a new physical input line.
      # Verb inheritance is allowed only between phrases from the same line.
      engine.state.set_flag(GameState::FLAG_VERB, ProcessRunner::WILDCARD_UNDERSCORE)
    end

    def mark_timeout_occurred
      flags = engine.state.get_flag(GameState::FLAG_TIMEOUT_FLAGS)
      engine.state.set_flag(GameState::FLAG_TIMEOUT_FLAGS, flags | TIMEOUT_OCCURRED_BIT)
    end

    def clear_timeout_occurred
      flags = engine.state.get_flag(GameState::FLAG_TIMEOUT_FLAGS)
      return if flags.zero?

      engine.state.set_flag(GameState::FLAG_TIMEOUT_FLAGS, flags & TIMEOUT_CONTROL_MASK)
    end

    def process_current_phrase
      current_phrase = phrase_queue.shift
      engine.log("🔍 Processing phrase: #{engine.interface.fmt_word(current_phrase)}", 2)

      engine.parse_input(current_phrase)
      engine.store_parsed_words
      engine.log_parser_result

      (engine.current_verb || engine.current_noun) ? :found : :not_found
    end

    def phrase_queue
      engine.phrase_queue
    end
  end
end
