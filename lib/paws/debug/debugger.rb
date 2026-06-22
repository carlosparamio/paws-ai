# frozen_string_literal: true

require "shellwords"
require_relative "debug_command_parser"
require_relative "debug_dumps"
require_relative "debug_state_commands"
require_relative "../interface/autoplay_script"

module PAWS
  # Interactive debugger for the PAWS engine.
  # Debugger is now the console coordinator: it owns the breakpoint REPL,
  # high-level command dispatch, stepping/continue/abort decisions, and
  # breakpoint management commands.
  #
  # Parsing raw input is delegated to DebugCommandParser, read-only presentation
  # is delegated to DebugDumps, and state mutations are delegated to
  # DebugStateCommands. That keeps the debug console close to a Command pattern
  # without hiding the simple REPL flow that is useful during manual playtests.
  class Debugger
    attr_accessor :remote_controller

    def initialize(engine)
      @engine = engine
      @interface = engine.interface
      @state = engine.state
      @game_data = engine.game_data
      @breakpoint_manager = engine.breakpoint_manager
      @command_parser = DebugCommandParser.new
      @dumps = DebugDumps.new(engine)
      @state_commands = DebugStateCommands.new(engine)
      @remote_controller = nil
    end

    def with_interface(interface)
      old_interface = @interface
      old_dumps = @dumps
      old_state_commands = @state_commands
      @interface = interface
      @dumps = DebugDumps.new(@engine, interface: interface)
      @state_commands = DebugStateCommands.new(@engine, interface: interface)
      yield
    ensure
      @interface = old_interface
      @dumps = old_dumps
      @state_commands = old_state_commands
    end

    def breakpoint_reached(p, b, c, reason: nil)
      return @remote_controller.breakpoint_reached(p, b, c, reason: reason) if @remote_controller

      @engine.stepping = false
      @interface.output_text("\n" + "=" * 40)
      loc_str = "[#{@interface.fmt_p(p)}|#{@interface.fmt_b(b)}|#{@interface.fmt_c(c)}]"
      @interface.output_text("🛑 BREAKPOINT REACHED #{loc_str}")
      @interface.output_text("   Reason: #{reason}") if reason
      @interface.output_text("=" * 40)

      # Auto-dump code if stepping
      dump_current_process(p, b, c) if reason == "Step"

      loop do
        @interface.output_text("\nDEBUG (f:flags, t:stack, p:code, s:step, b:break, c:cont, x:exit, ?:help) > ", newline: false)
        break unless handle_repl_input(@interface.get_input(timeout: nil, prompt: ""), p: p, b: b, c: c)
      end
    end

    def handle_repl_input(input, p:, b:, c:)
      command = @command_parser.parse(input)
      base = command.base
      arg = command.arg

      case base
      when "?", "h"
        show_help
      when "sf"
        dump_system_flags
      when "uf"
        dump_user_flags
      when "kuf"
        dump_known_user_flags
      when /^f(\d+)=(\d+)$/i
        @state_commands.set_flag($1.to_i, $2.to_i)
      when /^l=(\d+)$/i
        @state_commands.jump_to_location($1.to_i)
      when /^o(\d+)=(.+)$/i
        @state_commands.move_object($1.to_i, $2)
      when /^vb=(\d+)$/i
        @state_commands.set_verbosity($1.to_i)
      when "set"
        @state_commands.handle_set(arg)
      when "e"
        dump_engine_info
      when "t"
        dump_stack
      when "p"
        handle_p(arg, p, b, c)
      when "s", "step"
        @engine.stepping = true
        return false
      when "b"
        handle_b(command.parts)
      when /^f(\d+)$/
        dump_flag($1.to_i)
      when "f"
        dump_state
      when /^l(\d+)$/
        dump_locations($1)
      when "l"
        dump_locations(arg)
      when /^m(\d+)$/
        dump_messages($1)
      when "m"
        dump_messages(arg)
      when /^sys(\d+)$/
        dump_system_messages($1)
      when "sys"
        dump_system_messages(arg)
      when /^o(\d+)$/
        dump_objects($1)
      when "o"
        dump_objects(arg)
      when /^v(\d+)$/
        dump_vocabulary($1)
      when "v"
        dump_vocabulary(arg)
      when /^con(\d*)$/
        dump_connections($1.empty? ? (arg || @state.location) : $1)
      when "hist"
        list_history(arg)
      when "undo"
        rewind_to_previous
      when "rewind"
        rewind_to_index(arg)
      when "autoplay"
        handle_autoplay(command.raw)
      when "c", "continue", nil, ""
        return false
      when "x", "exit"
        @engine.abort_execution = true
        return false
      when "q", "quit"
        @engine.stop
        return false
      else
        @interface.output_text("Unknown command: #{command.normalized}. Type '?' for help.")
      end

      true
    end

    private

    def show_help
      @interface.output_text("Available commands:")
      @interface.output_text("  s / step      : Step execution")
      @interface.output_text("  c / continue  : Continue execution until next breakpoint")
      @interface.output_text("  x / exit      : Abort execution and return to input")
      @interface.output_text("  q / quit      : Quit game")
      @interface.output_text("----------------------------------------------------------")
      @interface.output_text("  p [spec]      : Show process/block code (e.g. p p2b3)")
      @interface.output_text("  t             : Show process stack trace")
      @interface.output_text("----------------------------------------------------------")
      @interface.output_text("  f[n]          : Show flags (non-zero or known) or flag n")
      @interface.output_text("  sf            : Show ALL system flags (0-59)")
      @interface.output_text("  uf            : Show ALL user flags (60-255)")
      @interface.output_text("  kuf           : Show only known user flags")
      @interface.output_text("  f<n>=<v>      : Set flag n to value v (e.g. f8=10)")
      @interface.output_text("  vb=<n>        : Set engine verbosity (0-3)")
      @interface.output_text("----------------------------------------------------------")
      @interface.output_text("  b [spec]      : Add execution breakpoint (e.g. b p2b3c1)")
      @interface.output_text("  b f<n><op><v> : Add flag breakpoint (e.g. b f8=10)")
      @interface.output_text("  b o<n>=<l>    : Add object location breakpoint (e.g. b o1=here)")
      @interface.output_text("  b             : List all active breakpoints")
      @interface.output_text("  b del <n>     : Delete breakpoint number n")
      @interface.output_text("----------------------------------------------------------")
      @interface.output_text("  l=<n>         : Jump player to location n (e.g. l=5)")
      @interface.output_text("  o<n>=<loc>    : Move object n to location loc (e.g. o1=here)")
      @interface.output_text("  e             : Show engine state info")
      @interface.output_text("  l[n]          : Inspect locations")
      @interface.output_text("  m[n]          : Inspect messages")
      @interface.output_text("  sys[n]        : Inspect system messages")
      @interface.output_text("  o[n]          : Inspect objects")
      @interface.output_text("  v[n]          : Inspect vocabulary")
      @interface.output_text("  con[n]        : Inspect connections")
      @interface.output_text("----------------------------------------------------------")
      @interface.output_text("  hist          : List state history snapshots")
      @interface.output_text("  hist <idx>    : Show details of snapshot at index N")
      @interface.output_text("  rewind <idx>  : Restore game state to index N")
      @interface.output_text("  undo          : Rewind to previous turn")
      @interface.output_text("  autoplay <file> <all|n-m> : Queue player commands from file lines")
      @interface.output_text("  ?             : Show this help message")
    end

    def dump_flag(n)
      @dumps.dump_flag(n)
    end

    def handle_p(arg, p_curr, b_curr, c_curr)
      if arg
        spec = @breakpoint_manager.parse_execution_spec(arg)
        if spec
          # Default to block 1 if only process is specified
          b_target = (spec[:block] == :any || spec[:block] == 0) ? 1 : spec[:block]
          c_target = (spec[:condact] == :any) ? 0 : spec[:condact]
          dump_current_process(spec[:process], b_target, c_target)
        else
          @interface.output_text("Invalid specification: #{arg} (Expected Pn, PnBm, or PnBmCk)")
        end
      else
        dump_current_process(p_curr, b_curr, c_curr)
      end
    end

    def handle_b(parts)
      case parts[1]
      when nil
        dump_breakpoints
      when "del", "delete", "rm"
        handle_delete_breakpoint(parts[2])
      else
        spec_str = parts[1..-1].join(" ")
        @breakpoint_manager.parse_line(spec_str)
        @interface.output_text("  Breakpoint added: #{spec_str}")
      end
    end

    def handle_delete_breakpoint(arg)
      if arg
        if @breakpoint_manager.remove_by_index(arg.to_i)
          @interface.output_text("  Breakpoint deleted.")
        else
          @interface.output_text("  Invalid breakpoint index: #{arg}")
        end
      else
        @interface.output_text("Usage: b del <n>")
      end
    end

    def handle_autoplay(raw)
      tokens = Shellwords.split(raw)
      path = tokens[1]
      range = tokens[2] || "all"

      unless path
        @interface.output_text("Usage: autoplay <file> <all|n-m>")
        return
      end

      begin
        commands = AutoplayScript.load(path, range: range)
      rescue AutoplayScript::Error => e
        @interface.output_text("  #{e.message}")
        return
      end

      @interface.install_autoplay_commands(commands)
      @interface.output_text("  Autoplay queued #{commands.length} command(s) from #{path} (#{range}).")
    end

    public

    def dump_state
      @dumps.dump_state
    end

    def dump_system_flags
      @dumps.dump_system_flags
    end

    def dump_user_flags
      @dumps.dump_user_flags
    end

    def dump_known_user_flags
      @dumps.dump_known_user_flags
    end

    def dump_engine_info
      @dumps.dump_engine_info
    end

    def dump_stack
      @dumps.dump_stack
    end

    def dump_current_process(process_id, block_index, condact_index)
      @dumps.dump_current_process(process_id, block_index, condact_index)
    end

    def dump_breakpoints
      @dumps.dump_breakpoints
    end

    def dump_locations(id)
      @dumps.dump_locations(id)
    end

    def dump_messages(id)
      @dumps.dump_messages(id)
    end

    def dump_system_messages(id)
      @dumps.dump_system_messages(id)
    end

    def dump_objects(id)
      @dumps.dump_objects(id)
    end

    def dump_vocabulary(id)
      @dumps.dump_vocabulary(id)
    end

    def dump_connections(location_id)
      @dumps.dump_connections(location_id)
    end

    def list_history(arg)
      history = @engine.state_history
      unless history
        @interface.output_text("  State history is only available in debug mode.")
        return
      end

      if history.empty?
        @interface.output_text("  No snapshots recorded yet.")
        return
      end

      if arg
        idx = arg.to_i
        entry = history[idx]
        if entry
          show_history_entry_detail(entry, idx)
        else
          @interface.output_text("  No snapshot found at index #{idx}.")
        end
        return
      end

      @interface.output_text("--- STATE HISTORY (#{history.size}/#{history.capacity}) ---")
      history.entries.each_with_index do |entry, idx|
        loc_name = @engine.location_text(entry.location)
        time_str = entry.timestamp.strftime("%H:%M:%S")
        input_str = entry.input ? " > #{entry.input}" : ""
        marker = idx == history.size - 1 ? " ◀ latest" : ""
        @interface.output_text("  [#{idx}] Turn #{entry.turn} @ #{time_str} — L#{entry.location} (#{loc_name})#{input_str}#{marker}")
      end
    end

    def show_history_entry_detail(entry, index = nil)
      loc_name = @engine.location_text(entry.location)
      time_str = entry.timestamp.strftime("%H:%M:%S.%L")
      @interface.output_text("--- SNAPSHOT DETAIL ---")
      @interface.output_text("  Index:    #{index}") if index
      @interface.output_text("  Time:     #{time_str}")
      @interface.output_text("  Location: L#{entry.location} (#{loc_name})")
      @interface.output_text("  Input:    #{entry.input || "(none)"}")

      non_zero_flags = entry.snapshot[:flags].each_with_index.map do |val, idx|
        "#{idx}=#{val}" if val != 0
      end.compact
      flags_str = non_zero_flags.empty? ? "(all zero)" : non_zero_flags.join(", ")
      @interface.output_text("  Flags:    #{flags_str}")
    end

    def rewind_to_previous
      history = @engine.state_history
      unless history && history.size >= 2
        @interface.output_text("  Not enough history to undo (need at least 2 snapshots).")
        return
      end

      idx = history.size - 2
      entry = history[idx]
      apply_snapshot(entry, idx)
      history.truncate_after(idx)
    end

    def rewind_to_index(arg)
      unless arg
        @interface.output_text("  Usage: rewind <index>")
        return
      end

      history = @engine.state_history
      unless history
        @interface.output_text("  State history is only available in debug mode.")
        return
      end

      idx = arg.to_i
      entry = history[idx]
      unless entry
        @interface.output_text("  No snapshot found at index #{idx}.")
        return
      end

      apply_snapshot(entry, idx)
      history.truncate_after(idx)
    end

    def apply_snapshot(entry, index = nil)
      @state.deserialize(entry.snapshot)
      @engine.describe_flag = true
      loc_name = @engine.location_text(entry.location)
      time_str = entry.timestamp.strftime("%H:%M:%S")
      input_str = entry.input ? " (input: '#{entry.input}')" : ""
      idx_str = index ? "Snapshot [#{index}] " : ""
      @interface.output_text("⏪ Rewound to #{idx_str}(Turn #{entry.turn}) @ #{time_str} — L#{entry.location} (#{loc_name})#{input_str}")
    end
  end
end
