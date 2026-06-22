# frozen_string_literal: true

require_relative "game_state"

module PAWS
  # Matches a process-table entry against the current logical sentence flags.
  # This is the PAWS flowchart-2 "Verb Match?" / "Noun Match?" decision extracted
  # as a Strategy object so ProcessRunner can focus on stack and execution flow.
  #
  # Automatic processes deserve special care: PAWS does not fill Verb/Noun from
  # parser input there, but games can still set F33/F34 explicitly with condacts
  # such as LET. When that happens, matching must honor those flags. This is what
  # drives PSI/NPC event dispatch in adventures that route dialogue through
  # automatic processes.
  class EntryMatcher
    MATCH_ALL = 0
    WILDCARD_STAR = 1
    WILDCARD_UNDERSCORE = 255

    def initialize(state_source)
      @state_source = state_source
    end

    def matches?(entry, mode:)
      # Mode is accepted to keep the public decision point explicit. Current PAWS
      # semantics use the same comparison in response and automatic processes.
      _mode = mode

      word_matches?(entry["verb"], state.get_flag(GameState::FLAG_VERB)) &&
        word_matches?(entry["noun"], state.get_flag(GameState::FLAG_NOUN1))
    end

    def wildcard?(value)
      value == WILDCARD_STAR || value == WILDCARD_UNDERSCORE
    end

    private

    attr_reader :state_source

    def state
      state_source.respond_to?(:state) ? state_source.state : state_source
    end

    def word_matches?(entry_word, logical_sentence_word)
      entry_word == MATCH_ALL ||
        entry_word == WILDCARD_STAR ||
        logical_sentence_word == WILDCARD_STAR ||
        entry_word == WILDCARD_UNDERSCORE ||
        entry_word == logical_sentence_word
    end
  end
end
