# frozen_string_literal: true

require_relative "location_ref"
require_relative "runtime_capabilities"
require_relative "object_reference_state"
require_relative "process_execution_context"
require_relative "process_control"
require_relative "do_all_executor"
require_relative "condact_execution"
require_relative "execution_result"
require_relative "entry_matcher"
require_relative "process_table_scanner"
require_relative "../condacts/registry"
require_relative "../condacts/handlers/flags"
require_relative "../condacts/handlers/conditions"
require_relative "../condacts/handlers/interface_effects"
require_relative "../condacts/handlers/runtime_state"
require_relative "../condacts/handlers/information"
require_relative "../condacts/handlers/flow_control"
require_relative "../condacts/handlers/object_copies"
require_relative "../condacts/handlers/persistence"
require_relative "../condacts/handlers/parsing"
require_relative "../condacts/handlers/object_lifecycle"
require_relative "../condacts/handlers/object_reference"
require_relative "../condacts/handlers/object_auto_actions"
require_relative "../condacts/handlers/object_inventory"

module PAWS
  # Executes PAWS process tables and controls condact flow.
  # This is the runtime coordinator below Engine: it owns process stack state,
  # response/automatic entry matching, DONE/NOTDONE semantics, debugger hooks,
  # and the legacy public condact methods used by older specs.
  #
  # The implementation is intentionally becoming a thin orchestrator. Condact
  # families are dispatched through CondactRegistry, single-condact bookkeeping
  # lives in CondactExecution, DOALL iteration lives in DoAllExecutor, and
  # mutable execution flags are represented by ProcessExecutionContext. That is
  # a Registry plus Command-style extraction rather than a new inheritance tree,
  # because PAWS condacts are data-driven opcodes from process tables.
  class ProcessRunner
    attr_reader :process_stack, :entry_index_stack, :condact_index_stack, :mode_stack,
                :execution_context

    def current_pid
      @process_stack.last || 0
    end

    def current_b_idx
      @entry_index_stack.last || 0
    end

    def current_c_idx
      @condact_index_stack.last || 0
    end

    def unsupported_condacts
      @condact_execution.unsupported_condacts
    end

    def current_condact
      @condact_execution.current_condact
    end

    def executing_condact?
      @condact_execution.executing?
    end

    def web_graphics_interface?
      @engine.interface.class.name == "PAWS::Web::Interface"
    end

    # Wildcards: * (ID 1) and _ (255) match any word.
    WILDCARD_STAR = 1    # * in vocabulary.
    WILDCARD_UNDERSCORE = 255  # _ (no word).

    SYSTEM_FLAGS = {
      0 => "Darkness",
      1 => "Objects Carried",
      2 => "Autodecrement 2",
      3 => "Autodecrement 3",
      4 => "Autodecrement 4",
      5 => "Autodecrement 5",
      6 => "Autodecrement 6",
      7 => "Autodecrement 7",
      8 => "Autodecrement 8",
      9 => "Autodecrement 9",
      10 => "Autodecrement 10",
      31 => "Turns (LO)",
      32 => "Turns (HI)",
      33 => "Verb",
      34 => "Noun 1",
      35 => "Adjective 1",
      36 => "Adverb",
      37 => "Max Objects Carried",
      38 => "Current Location",
      40 => "Screen Mode",
      42 => "Prompt",
      43 => "Preposition",
      44 => "Noun 2",
      45 => "Adjective 2",
      46 => "Pronoun",
      47 => "Pronoun Adjective",
      48 => "Timeout Length",
      49 => "Timeout Flags",
      50 => "DOALL Index",
      51 => "Referred Object",
      52 => "Max Weight",
      53 => "Listing Control",
      54 => "Referred Object Loc",
      55 => "Referred Object Weight",
      56 => "Referred Object Container",
      57 => "Referred Object Wearable",
    }.freeze

    CONDITIONS = %w[
      at notat atgt atlt present absent worn notworn carried notcarr
      chance zero notzero eq noteq gt lt same notsame bigger smaller
      isat isnotat adject1 adverb prep noun2 adject2 timeout
    ].freeze

    REGISTRY_BACKED_CONDACTS = %w[
      AT NOTAT ATGT ATLT PRESENT ABSENT WORN NOTWORN CARRIED NOTCARR CHANCE
      ZERO NOTZERO EQ NOTEQ GT LT SAME NOTSAME BIGGER SMALLER
      ISAT ISNOTAT ADJECT1 ADVERB PREP NOUN2 ADJECT2 TIMEOUT
      SET CLEAR LET PLUS MINUS COPYOF COPYOO COPYFO COPYFF COPYFB COPYBF EXTERN PROTECT
      ADD SUB RANDOM ABILITY WEIGHT TIME MOVE SAVEAT BACKAT INPUT NEWTEXT RESET_FLAG
      PARSE
      INVEN TURNS SCORE LISTOBJ LISTAT
      DONE NOTDONE OK DESC GOTO PROCESS RAMSAVE RAMLOAD SAVE LOAD END QUIT
      ANYKEY CLS PAUSE MESSAGE NEWLINE PRINT SYSMESS BEEP PAPER INK BORDER
      MES CHARSET MODE LINE PICTURE PROMPT GRAPHIC PRINTAT BELL
      CREATE DESTROY SWAP PLACE RESET
      WHATO PUTO WEIGH
      AUTOG AUTOD AUTOW AUTOR AUTOP AUTOT
      GET DROP WEAR REMOVE PUTIN TAKEOUT DROPALL
    ].freeze

    VISIBLE_EFFECT_CONDACTS = %w[
      MESSAGE MES SYSMESS PRINT NEWLINE LISTOBJ LISTAT INVEN TURNS SCORE ANYKEY CLS
      PICTURE GRAPHIC LINE PRINTAT MODE PAPER INK BORDER PROMPT CHARSET BEEP BELL PAUSE
    ].freeze

    RESPONSE_SCAN_THROUGH_CONDACTS = %w[LET].freeze

    REGISTRY_BACKED_CONDACTS.each do |condact_name|
      method_name = :"condact_#{condact_name.downcase}"
      define_method(method_name) { |*params| @condact_registry.call(condact_name, params) }
      private method_name
    end

    def initialize(engine)
      @engine = engine
      @process_stack = []
      @mode_stack = []
      @entry_index_stack = []
      @condact_index_stack = []
      @doall_stack = []
      @execution_context = ProcessExecutionContext.new
      @done_stack = @execution_context.done_stack
      @entry_matcher = EntryMatcher.new(@engine)
      @condact_registry = CondactRegistry.new
      @runtime_capabilities = web_graphics_interface? ? RuntimeCapabilities.web : RuntimeCapabilities.cli
      @object_reference_state = ObjectReferenceState.new(@engine)
      @process_control = ProcessControl.new(self)
      @do_all_executor = DoAllExecutor.new(
        engine: @engine,
        execution_context: @execution_context,
        object_reference: @object_reference_state,
        process_control: @process_control,
      )
      @condact_execution = CondactExecution.new(
        engine: @engine,
        registry: @condact_registry,
        runner: self,
        conditions: CONDITIONS,
        debug_prefix: ->(condact: false) { debug_prefix(condact: condact) },
        flag_info: ->(flag) { flag_info(flag) },
      )
      @process_table_scanner = ProcessTableScanner.new(
        engine: @engine,
        execution_context: @execution_context,
        entry_matcher: @entry_matcher,
        entry_index_stack: @entry_index_stack,
        condact_index_stack: @condact_index_stack,
        check_breakpoint: -> { check_breakpoint },
        run_condacts: ->(condacts) { run_condacts(condacts) },
        debug_prefix: -> { debug_prefix },
      )
      CondactHandlers::Flags.register(@condact_registry, @engine)
      CondactHandlers::Conditions.register(
        @condact_registry,
        @engine,
        random: ->(range) { rand(range) },
      )
      CondactHandlers::InterfaceEffects.register(
        @condact_registry,
        @engine,
        unsupported: ->(name, params, reason:) { @condact_execution.unsupported(name, params, reason: reason) },
        optional_noop: ->(name, params, reason:) { @condact_execution.optional_noop(name, params, reason: reason) },
        capabilities: @runtime_capabilities,
        sleeper: ->(seconds) { sleep(seconds) },
        bell: -> { print "\a" },
      )
      CondactHandlers::RuntimeState.register(
        @condact_registry,
        @engine,
        random: ->(limit) { rand(limit) },
      )
      CondactHandlers::Information.register(@condact_registry, @engine)
      CondactHandlers::FlowControl.register(
        @condact_registry,
        @engine,
        execution_context: @execution_context,
        process_control: @process_control,
      )
      CondactHandlers::ObjectCopies.register(
        @condact_registry,
        @engine,
        object_reference: @object_reference_state,
      )
      CondactHandlers::Persistence.register(
        @condact_registry,
        @engine,
        execution_context: @execution_context,
      )
      CondactHandlers::Parsing.register(@condact_registry, @engine)
      CondactHandlers::ObjectLifecycle.register(
        @condact_registry,
        @engine,
        object_reference: @object_reference_state,
      )
      CondactHandlers::ObjectReference.register(
        @condact_registry,
        @engine,
        object_reference: @object_reference_state,
      )
      CondactHandlers::ObjectAutoActions.register(@condact_registry, @engine)
      CondactHandlers::ObjectInventory.register(
        @condact_registry,
        @engine,
        object_reference: @object_reference_state,
        execution_context: @execution_context,
      )
    end

    def run_process(process_id, mode: nil)
      process = @engine.game_data_repository.process(process_id)
      return unless process

      # If no mode is specified, inherit the parent mode or default to :response.
      mode ||= @mode_stack.last || :response

      if @engine.verbosity >= 2
        @engine.log("▶️  Executing #{@engine.interface.fmt_p(process_id)} (#{mode})", 2)
      end

      @process_stack.push(process_id)
      @mode_stack.push(mode)
      @entry_index_stack.push(0)
      @condact_index_stack.push(0)
      @execution_context.push_frame
      begin
        check_breakpoint
        run_entries(process["entries"] || [])
      ensure
        if @engine.verbosity >= 2
          @engine.log("⏹️  Finished executing #{@engine.interface.fmt_p(process_id)}", 2)
          if @process_stack.size > 1
            parent_p = @process_stack[-2]
            parent_b = @entry_index_stack[-2]
            parent_c = @condact_index_stack[-2]
            @engine.log("↩️  Returning to [#{@engine.interface.fmt_p(parent_p)}|#{@engine.interface.fmt_b(parent_b)}|#{@engine.interface.fmt_c(parent_c)}]", 2)
          end
        end

        child_done = @execution_context.pop_frame
        @condact_index_stack.pop
        @entry_index_stack.pop
        @mode_stack.pop
        @process_stack.pop

        # The global engine needs to know whether DONE was reached for turn flow.
        # Propagate it only when the child ended with DONE and is not an automatic process.
        # Automatic processes (1 and 2) must not restart the engine turn cycle.
        if child_done && mode != :automatic
          @engine.set_done
        end
      end
    end

    def check_breakpoint
      p = @process_stack.last
      b = @entry_index_stack.last
      c = @condact_index_stack.last

      wait_for_remote_debugger
      return if @engine.abort_execution

      # Step-by-step mode (s/step).
      if @engine.stepping
        current_point = [p, b, c]
        return if @engine.step_resume_after && compare_step_point(current_point, @engine.step_resume_after) <= 0

        @engine.step_resume_after = nil
        if current_point != @engine.last_step_point
          @engine.instance_variable_set(:@last_step_point, current_point)
          @engine.breakpoint_reached(p, b, c, reason: "Step")
          return # Once stopped, skip regular breakpoints in this cycle.
        end
      end

      # Breakpoints defined by file or the 'b' command.
      if @engine.breakpoint_manager.check_execution?(p, b, c)
        @engine.instance_variable_set(:@last_step_point, [p, b, c])
        @engine.breakpoint_reached(p, b, c)
      end
    end

    def dump_game_state
      @engine.interface.output_text("\n--- GAME STATE DUMP ---")
      @engine.interface.output_text("Location: #{@engine.state.location}")
      @engine.interface.output_text("Flags:")
      (0..255).each do |i|
        val = @engine.state.get_flag(i)
        # Show system flags or flags with a value greater than zero.
        if val > 0 || SYSTEM_FLAGS.key?(i)
          name = SYSTEM_FLAGS[i] ? " (#{SYSTEM_FLAGS[i]})" : ""
          @engine.interface.output_text("  F#{i.to_s.ljust(3)}: #{val.to_s.ljust(3)}#{name}")
        end
      end
      @engine.interface.output_text("-----------------------\n")
    end

    def execute_condact(condact)
      @condact_execution.execute(condact)
    end

    def ensure_condact_logged
      @condact_execution.ensure_logged
    end

    private

    def compare_step_point(left, right)
      left <=> right
    end

    def wait_for_remote_debugger
      debugger = @engine.respond_to?(:debugger) ? @engine.debugger : nil
      controller = debugger.respond_to?(:remote_controller) ? debugger.remote_controller : nil

      controller.wait_if_paused if controller&.respond_to?(:wait_if_paused)
    end

    def wildcard?(value)
      @entry_matcher.wildcard?(value)
    end

    def action_condact?(condact)
      VISIBLE_EFFECT_CONDACTS.include?(condact.fetch("name").upcase)
    end

    def run_entries(entries)
      mode = @mode_stack.last || :response
      @process_table_scanner.call(entries, mode: mode)
    end

    def run_condacts(condacts, start_index = 0)
      idx = start_index
      continue_scan = false
      handled_before_failure = false
      while idx < condacts.length
        return :abort if @engine.abort_execution
        @condact_index_stack[-1] = idx + 1
        check_breakpoint
        condact = condacts[idx]

        # DOALL is special because it needs the remaining condacts.
        if condact["name"].upcase == "DOALL"
          params = condact["params"] || []
          log_condact("DOALL", params, :ok) if @engine.verbosity >= 3
          return condact_doall(params[0], condacts[(idx + 1)..-1])
        end

        result = ExecutionResult.from(execute_condact(condact))
        return handled_before_failure ? :done : :failed if result.failed?
        return :abort if result.abort?
        return ExecutionResult.continue_scan(condacts[(idx + 1)..] || []) if result.continue_scan?

        continue_scan ||= result.continue_scan?
        handled_before_failure ||= action_condact?(condact)
        @execution_context.mark_done if result.done? && @mode_stack.last == :response

        return :done if @execution_context.done?
        idx += 1
      end
      return :continue_scan if response_scan_through_entry?(condacts)

      continue_scan ? :continue_scan : :ok
    end

    public :run_condacts

    private

    def response_scan_through_entry?(condacts)
      @mode_stack.last == :response &&
        condacts.any? &&
        condacts.all? { |condact| RESPONSE_SCAN_THROUGH_CONDACTS.include?(condact.fetch("name").upcase) }
    end

    def flag_info(n)
      name = @engine.flag_name(n)
      desc = name ? " [#{@engine.interface.colorize(name, :yellow)}]" : ""
      "#{@engine.interface.fmt_flag(n)}#{desc}"
    end

    def log_condact(name, params, result, old_val: nil)
      @condact_execution.log(name, params, result, old_val: old_val)
    end

    def debug_prefix(condact: false)
      p_id = @process_stack.last
      b_id = @entry_index_stack.last
      c_id = @condact_index_stack.last

      parts = []
      parts << @engine.interface.fmt_p(p_id) if p_id
      parts << @engine.interface.fmt_b(b_id) if b_id && b_id > 0
      parts << @engine.interface.fmt_c(c_id) if condact && c_id && c_id > 0

      @engine.interface.colorize("[#{parts.join("|")}]", :dim)
    end

    # ============================================================
    # HELPERS
    # ============================================================

    def resolve_loc(loc)
      LocationRef.parse(loc).resolve(current_location: @engine.state.location)
    end

    def unsupported_condact(name, params = [], reason:)
      @condact_execution.unsupported(name, params, reason: reason)
    end

    def optional_noop_condact(name, params = [], reason:)
      @condact_execution.optional_noop(name, params, reason: reason)
    end

    def condact_doall(loc, remaining_condacts)
      @do_all_executor.call(loc, remaining_condacts)
    end
  end
end
