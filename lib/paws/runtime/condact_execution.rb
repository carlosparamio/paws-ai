# frozen_string_literal: true

require_relative "game_state"
require_relative "execution_result"

module PAWS
  # Executes one condact at a time and records the observable execution trace.
  # This object is the dispatch boundary between ProcessRunner and the handler
  # registry. It owns transient "currently executing condact" state, eager debug
  # logging, pending-breakpoint checks, and the list of unsupported runtime
  # features encountered during play.
  #
  # Keeping this separate from ProcessRunner prevents logging and unsupported
  # capability reporting from leaking into every handler. Handlers can focus on
  # domain effects and return small status values. ExecutionResult normalizes
  # legacy symbols/arrays at this boundary.
  class CondactExecution
    FLAG_CHANGE_ACTIONS = %w[SET CLEAR PLUS MINUS LET COPYFF COPYFO COPYOF COPYOO].freeze
    EAGER_LOG_CONDACTS = %w[PROCESS PAUSE ANYKEY INPUT SAVE LOAD RAMLOAD CLS].freeze

    attr_reader :unsupported_condacts, :current_condact

    def initialize(engine:, registry:, runner:, conditions:, debug_prefix:, flag_info:)
      @engine = engine
      @registry = registry
      @runner = runner
      @conditions = conditions
      @debug_prefix = debug_prefix
      @flag_info = flag_info
      @unsupported_condacts = []
      @current_condact = nil
      @condact_logged = false
    end

    def executing?
      !!@current_condact
    end

    def execute(condact)
      name = condact["name"].upcase
      params = condact["params"] || []
      method_name = "condact_#{name.downcase}"
      registry_handler = @registry.registered?(name)

      return unsupported(name, params, reason: "not implemented") unless registry_handler || @runner.respond_to?(method_name, true)

      is_condition = condition?(name)
      old_val = old_flag_value(name, params, is_condition)

      @current_condact = condact
      @condact_logged = false
      ensure_logged if EAGER_LOG_CONDACTS.include?(name)

      result = normalize_result(if registry_handler
        @registry.call(name, params)
      else
        @runner.__send__(method_name, *params)
      end)

      log(name, params, result, old_val: old_val) unless name == "PROCESS" && !@condact_logged

      @current_condact = nil
      @condact_logged = false

      @engine.check_pending_breakpoint

      result
    end

    def ensure_logged
      return if !@current_condact || @condact_logged

      name = @current_condact["name"]
      params = @current_condact["params"] || []
      log(name, params, :executing)
    end

    def log(name, params, result, old_val: nil)
      is_condition = condition?(name)

      # Skip redundant 'ok' for actions that were already logged as starting.
      result = normalize_result(result)
      return if !is_condition && result.ok? && @condact_logged

      @condact_logged = true
      prefix = @engine.verbosity >= 3 ? "#{debug_prefix(condact: true)}            " : ""
      status = result.status
      details = result.details

      res_str = result_suffix(is_condition, status)
      if @engine.verbosity >= 3 && details
        res_str = "#{res_str}#{res_str.empty? ? " " : ", "}#{details}"
      end

      reminders = flag_reminders(name, params, is_condition, old_val)
      rem_str = reminders.empty? ? "" : " (#{@engine.interface.colorize(reminders.join(", "), :dim)})"

      @engine.log("#{prefix}📜 #{@engine.interface.fmt_condact(name)}(#{params.join(", ")})#{res_str}#{rem_str}", 2)
    end

    def unsupported(name, params = [], reason:)
      entry = { name: name, params: params, reason: reason.to_s }
      entry[:feature] = reason.feature if reason.respond_to?(:feature)
      @unsupported_condacts << entry

      prefix = @engine.verbosity >= 3 ? "#{debug_prefix(condact: true)}            " : ""
      message = "Unsupported condact: #{name} (#{reason})"
      @engine.log("#{prefix}#{message}", 2)
      warn message if warn_unsupported?

      ExecutionResult.unsupported
    end

    def optional_noop(name, _params = [], reason:)
      return ExecutionResult.ok unless @engine.verbosity >= 3

      prefix = "#{debug_prefix(condact: true)}            "
      @engine.log("#{prefix}Optional no-op condact: #{name} (#{reason})", 3)
      ExecutionResult.ok
    end

    private

    def condition?(name)
      @conditions.include?(name.downcase)
    end

    def warn_unsupported?
      @engine.verbosity.positive? &&
        !(@engine.interface.respond_to?(:suppress_unsupported_warnings?) &&
          @engine.interface.suppress_unsupported_warnings?)
    end

    def normalize_result(result)
      ExecutionResult.from(result)
    end

    def old_flag_value(name, params, is_condition)
      return nil if is_condition || !FLAG_CHANGE_ACTIONS.include?(name)

      flag = params[0]
      @engine.state.get_flag(flag) if flag && flag.is_a?(Integer) && flag < 256
    end

    def result_suffix(is_condition, status)
      return "" unless is_condition

      status_style = status == :failed ? [:red, :bold] : [:green]
      " #{@engine.interface.colorize(status.to_s, *status_style)}"
    end

    def flag_reminders(name, params, is_condition, old_val)
      reminders = []
      show_reminders = is_condition || @engine.verbosity == 2
      return reminders unless show_reminders

      if %w[EQ NOTZERO ZERO NOTEQ SET CLEAR PLUS MINUS LET GT LT RANDOM INPUT].include?(name)
        add_single_flag_reminder(reminders, params[0], old_val, is_condition)
      elsif %w[ADD SUB COPYFF].include?(name)
        add_source_and_target_flag_reminders(reminders, params, old_val)
      elsif %w[SAME NOTSAME BIGGER SMALLER].include?(name)
        add_comparison_flag_reminders(reminders, params)
      end

      reminders
    end

    def add_single_flag_reminder(reminders, flag, old_val, is_condition)
      return unless flag && flag.is_a?(Integer) && flag < 256

      val = old_val || @engine.state.get_flag(flag)
      verb = (old_val && !is_condition) ? "was" : "is"
      reminders << "#{flag_info(flag)} #{verb} #{@engine.interface.fmt_val(val)}"
    end

    def add_source_and_target_flag_reminders(reminders, params, old_val)
      flag1 = params[0]
      flag2 = params[1]

      if flag1 && flag1.is_a?(Integer) && flag1 < 256
        reminders << "#{flag_info(flag1)} was #{@engine.interface.fmt_val(old_val || @engine.state.get_flag(flag1))}"
      end

      if flag2 && flag2.is_a?(Integer) && flag2 < 256
        reminders << "#{flag_info(flag2)} is #{@engine.interface.fmt_val(@engine.state.get_flag(flag2))}"
      end
    end

    def add_comparison_flag_reminders(reminders, params)
      flag1 = params[0]
      flag2 = params[1]

      if flag1 && flag1.is_a?(Integer) && flag1 < 256
        reminders << "#{flag_info(flag1)}=#{@engine.interface.fmt_val(@engine.state.get_flag(flag1))}"
      end

      if flag2 && flag2.is_a?(Integer) && flag2 < 256
        reminders << "#{flag_info(flag2)}=#{@engine.interface.fmt_val(@engine.state.get_flag(flag2))}"
      end
    end

    def debug_prefix(condact: false)
      @debug_prefix.call(condact: condact)
    end

    def flag_info(flag)
      @flag_info.call(flag)
    end
  end
end
