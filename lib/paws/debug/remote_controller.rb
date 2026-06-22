# frozen_string_literal: true

require "thread"
require "time"
require_relative "capture_interface"

module PAWS
  module Debug
    class RemoteController
      PAUSE_COMMANDS = %w[pause stop halt interrupt].freeze

      attr_reader :id, :game_name

      def initialize(engine, id:, game_name:, logger: nil)
        @engine = engine
        @id = id
        @game_name = game_name
        @logger = logger || ->(_message) {}
        @mutex = Mutex.new
        @condition = ConditionVariable.new
        @paused = false
        @current = nil
        @log = []
        @nonblocking_breakpoints = false
      end

      def breakpoint_reached(p, b, c, reason:)
        pause_now(p: p, b: b, c: c, reason: reason, dump_process: reason == "Step")
        throw :remote_debug_pause if nonblocking_breakpoints?

        wait_if_paused
      end

      def with_nonblocking_breakpoints
        previous = @nonblocking_breakpoints
        @nonblocking_breakpoints = true
        yield
      ensure
        @nonblocking_breakpoints = previous
      end

      def pause_now(p: nil, b: nil, c: nil, reason: "Manual remote request", dump_process: false)
        @engine.stepping = false if @engine.respond_to?(:stepping=)
        p, b, c = current_execution_location if p.nil? || b.nil? || c.nil?
        output = capture_breakpoint_banner(p, b, c, reason, dump_process: dump_process)

        @mutex.synchronize do
          @paused = true
          @current = {
            "process" => p,
            "block" => b,
            "condact" => c,
            "reason" => reason,
            "at" => Time.now.utc.iso8601,
          }
          append_log_locked(output)
          @logger.call(format("[debug] paused %s P%03d B%03d C%03d %s", @id, p, b, c, reason))
          @condition.broadcast
        end
        output
      end

      def wait_if_paused
        @mutex.synchronize do
          @condition.wait(@mutex) while @paused && engine_running? && !engine_abort_execution?
        end
      end

      def execute(command)
        command = command.to_s.strip

        if pause_command?(command)
          output = paused? ? "Engine already paused.\n" : pause_now(reason: "Manual remote request")
          @mutex.synchronize { append_log_locked(output) } if paused? && output.start_with?("Engine already paused.")
          return command_result(true, "pause", output)
        end

        if engine_stepping && !paused?
          output = "Engine is stepping; wait for the next breakpoint.\n"
          @mutex.synchronize { append_log_locked(output) }
          return command_result(false, action_for(command), output)
        end

        pause_output = +""
        pause_output << pause_now(reason: "Manual remote request") unless paused?

        p, b, c = current_location_values
        capture = CaptureInterface.new(@engine.interface)
        keep_paused = true

        @engine.debugger.with_interface(capture) do
          keep_paused = @engine.debugger.handle_repl_input(command, p: p, b: b, c: c)
        end

        command_output = capture.flush
        output = pause_output + command_output
        @mutex.synchronize { append_log_locked(command_output) }
        action = action_for(command)
        release! unless keep_paused
        append_control_command_log(action)
        command_result(true, action, output)
      rescue StandardError => e
        output = "#{e.class}: #{e.message}\n"
        @mutex.synchronize { append_log_locked(output) }
        @logger.call("[debug] command error #{@id} #{e.class}: #{e.message}")
        command_result(false, "none", output)
      end

      def paused?
        @mutex.synchronize { @paused }
      end

      def state
        @mutex.synchronize do
          {
            "session_id" => @id,
            "game" => @game_name,
            "status" => status_locked,
            "breakpoint" => @current&.dup,
            "engine" => engine_state,
            "breakpoints" => breakpoints,
            "log" => @log.dup,
          }
        end
      end

      def summary
        @mutex.synchronize do
          {
            "session_id" => @id,
            "game" => @game_name,
            "status" => status_locked,
            "breakpoint" => @current&.dup,
          }
        end
      end

      private

      def capture_breakpoint_banner(p, b, c, reason, dump_process: false)
        capture = CaptureInterface.new(@engine.interface)
        @engine.debugger.with_interface(capture) do
          capture.output_text("\n" + "=" * 40)
          loc_str = "[#{capture.fmt_p(p)}|#{capture.fmt_b(b)}|#{capture.fmt_c(c)}]"
          capture.output_text("🛑 BREAKPOINT REACHED #{loc_str}")
          capture.output_text("   Reason: #{reason}") if reason
          capture.output_text("=" * 40)
          @engine.debugger.dump_current_process(p, b, c) if dump_process
        end
        capture.flush
      end

      def current_location_values
        @mutex.synchronize do
          current = @current || {}
          [current["process"].to_i, current["block"].to_i, current["condact"].to_i]
        end
      end

      def release!
        @mutex.synchronize do
          @paused = false
          @condition.broadcast
        end
      end

      def command_result(ok, action, output)
        { "ok" => ok, "action" => action, "output" => output, "state" => state }
      end

      def action_for(command)
        case command.split(/\s+/, 2).first.to_s.downcase
        when *PAUSE_COMMANDS
          "pause"
        when "", "c", "continue"
          "continue"
        when "s", "step"
          "step"
        when "x", "exit"
          "exit"
        when "q", "quit"
          "quit"
        else
          "none"
        end
      end

      def append_control_command_log(action)
        message =
          case action
          when "continue"
            "Continue: engine resumed.\n"
          when "exit"
            "Exit: debugger closed and current execution aborted.\n"
          else
            ""
          end
        return if message.empty?

        @mutex.synchronize { append_log_locked(message) }
      end

      def pause_command?(command)
        PAUSE_COMMANDS.include?(command.split(/\s+/, 2).first.to_s.downcase)
      end

      def current_execution_location
        runner =
          if @engine.respond_to?(:runner)
            @engine.runner
          elsif @engine.respond_to?(:process_runner)
            @engine.process_runner
          end
        return [0, 0, 0] unless runner

        [
          Array(runner.respond_to?(:process_stack) ? runner.process_stack : []).last.to_i,
          Array(runner.respond_to?(:entry_index_stack) ? runner.entry_index_stack : []).last.to_i,
          Array(runner.respond_to?(:condact_index_stack) ? runner.condact_index_stack : []).last.to_i,
        ]
      end

      def status_locked
        return "paused" if @paused
        return "running" if engine_running?

        "stopped"
      end

      def engine_state
        state = @engine.respond_to?(:state) ? @engine.state : nil

        {
          "location" => state&.location,
          "turns" => state&.turns,
          "running" => engine_running?,
          "stepping" => engine_stepping,
          "abort_execution" => engine_abort_execution?,
        }
      end

      def engine_running?
        return @engine.running? if @engine.respond_to?(:running?)

        true
      end

      def engine_abort_execution?
        @engine.respond_to?(:abort_execution) && @engine.abort_execution
      end

      def engine_stepping
        @engine.respond_to?(:stepping) ? @engine.stepping : false
      end

      def breakpoints
        return [] unless @engine.respond_to?(:breakpoint_manager)
        return [] unless @engine.breakpoint_manager.respond_to?(:breakpoints)

        @engine.breakpoint_manager.breakpoints
      end

      def append_log_locked(output)
        return if output.to_s.empty?

        @log << { "at" => Time.now.utc.iso8601, "output" => output }
        @log.shift while @log.size > 100
      end

      def nonblocking_breakpoints?
        @nonblocking_breakpoints
      end
    end
  end
end
