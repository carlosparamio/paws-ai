# frozen_string_literal: true

require_relative "execution_result"

module PAWS
  # Iterates the entries of a PAWS process table.
  # This class is the runtime Scanner for PAWS flowchart 2: it advances the
  # entry/condact debug coordinates, asks EntryMatcher whether the current
  # logical sentence matches an entry, and delegates matching entries back to
  # ProcessRunner for condact execution.
  #
  # The scanner deliberately does not know about individual condacts, DOALL, or
  # DONE implementation details. Those remain in ProcessRunner and the extracted
  # condact handlers; the scanner only enforces the table traversal contract.
  class ProcessTableScanner
    def initialize(engine:, execution_context:, entry_matcher:, entry_index_stack:, condact_index_stack:, check_breakpoint:, run_condacts:, debug_prefix:)
      @engine = engine
      @execution_context = execution_context
      @entry_matcher = entry_matcher
      @entry_index_stack = entry_index_stack
      @condact_index_stack = condact_index_stack
      @check_breakpoint = check_breakpoint
      @run_condacts = run_condacts
      @debug_prefix = debug_prefix
    end

    def call(entries, mode:)
      if engine.verbosity >= 3 && entries.any?
        engine.log("#{debug_prefix} 🔄 Processing #{entries.length} entries", 3)
      end

      deferred_condacts = nil

      entries.each_with_index do |entry, idx|
        break if halt?

        entry_index_stack[-1] = idx + 1
        condact_index_stack[-1] = 0
        check_breakpoint.call

        next unless entry_matcher.matches?(entry, mode: mode)

        log_entry_match(entry)
        execution_context.begin_entry
        result = normalize_condact_result(run_condacts.call(entry["condacts"] || []))
        if result.continue_scan? && result.details && !result.details.empty?
          deferred_condacts = result.details
        end
        if mode == :response && result != :failed && result != :continue_scan && !execution_context.notdone?
          execution_context.mark_done
        end

        break if halt?
      end

      return unless mode == :response && deferred_condacts && !halt?

      result = normalize_condact_result(run_condacts.call(deferred_condacts))
      execution_context.mark_done if result != :failed && result != :continue_scan
    end

    private

    attr_reader :engine, :execution_context, :entry_matcher, :entry_index_stack,
                :condact_index_stack, :check_breakpoint, :run_condacts

    def normalize_condact_result(result)
      return ExecutionResult.ok if result.nil? || result == true
      return ExecutionResult.from(result) if result.is_a?(ExecutionResult)
      return ExecutionResult.from(result) if result.is_a?(Symbol)
      return ExecutionResult.from(result) if result.is_a?(String)
      return ExecutionResult.from(result) if result.is_a?(Array) && result.first.is_a?(Symbol)

      ExecutionResult.ok
    end

    def debug_prefix
      @debug_prefix.call
    end

    def halt?
      execution_context.done? || !engine.running? || engine.abort_execution
    end

    def log_entry_match(entry)
      return unless engine.verbosity >= 3

      verb_str = engine.vocabulary_word(entry["verb"], 0).ljust(5)
      noun_str = engine.vocabulary_word(entry["noun"], 2).ljust(5)
      engine.log("#{debug_prefix}      #{verb_str} #{noun_str}", 2)
    end
  end
end
