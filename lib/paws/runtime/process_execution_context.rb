# frozen_string_literal: true

module PAWS
  # Holds mutable execution bookkeeping for process frames.
  # Condact handlers use this object to mark DONE/NOTDONE and request DOALL
  # aborts without knowing how ProcessRunner stores its internal stacks.
  #
  # This is intentionally tiny: it is a context object, not a second runner. Its
  # job is to give extracted handlers a stable vocabulary for execution state
  # while ProcessRunner remains responsible for the actual process loop.
  class ProcessExecutionContext
    attr_reader :done_stack

    def initialize
      @done_stack = []
      @notdone_stack = []
      @abort_doall = false
    end

    def push_frame
      done_stack.push(false)
      @notdone_stack.push(false)
    end

    def pop_frame
      @notdone_stack.pop
      done_stack.pop
    end

    def done?
      !!done_stack.last
    end

    def mark_done
      ensure_frame
      done_stack[-1] = true
      @notdone_stack[-1] = false
    end

    def mark_notdone
      ensure_frame
      done_stack[-1] = false
      @notdone_stack[-1] = true
    end

    def begin_entry
      ensure_frame
      @notdone_stack[-1] = false
    end

    def notdone?
      !!@notdone_stack.last
    end

    def reset_doall_abort
      @abort_doall = false
    end

    def abort_doall!
      @abort_doall = true
    end

    def abort_doall?
      @abort_doall
    end

    private

    def ensure_frame
      push_frame if done_stack.empty?
    end
  end
end
