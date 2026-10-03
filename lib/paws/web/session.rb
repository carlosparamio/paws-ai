# frozen_string_literal: true

require "json"
require_relative "../interface/autoplay_script"
require_relative "../utils/color_utils"
require_relative "../utils/text_markup"
require_relative "../runtime/engine"
require_relative "graphics_presenter"
require_relative "interface"
require_relative "protocol"
require_relative "screen_model"

module PAWS
  module Web
    # Owns one running game instance for the web UI.
    #
    # This is intentionally synchronous for the first web vertical. The browser
    # submits one command, the Ruby engine advances one PAW turn, and the session
    # returns all emitted events. The same event stream can later be pushed over
    # a WebSocket connection.
    class Session
      attr_reader :id

      def initialize(id:, game_data:, game_name: "game", engine_options: {}, command_history_path: nil, transcript_path: nil, autoplay_path: nil, autoplay_range: nil, text_renderer: "pc", graphics_mode: "original", font_size: nil, ai_graphics: nil, debug_controller_factory: nil)
        @id = id
        @game_data = game_data
        @game_name = game_name
        @engine_options = engine_options
        @debug_mode = !!engine_options[:debug_mode]
        @debug_controller_factory = debug_controller_factory
        @remote_debug = !debug_controller_factory.nil?
        @debug_output = (!@remote_debug && @debug_mode) || engine_options.fetch(:verbosity, 0).positive?
        @text_renderer = text_renderer.to_s
        @graphics_mode = graphics_mode.to_s
        @font_size = font_size
        @ai_graphics = ai_graphics
        @command_history = open_output_file(command_history_path)
        @interface = Interface.new(
          transcript_path: transcript_path,
          paginate_screen_text: @text_renderer == "spectrum",
          persist_screen_cursor_after_process: @text_renderer == "spectrum",
          graphics_enabled: graphics_enabled?,
        )
        @interface.install_autoplay_commands(load_autoplay_commands(autoplay_path, range: autoplay_range)) if autoplay_path
        @screen_model = ScreenModel.new
        apply_initial_text_attributes
        @graphics = GraphicsPresenter.new(game_data)
        @engine = PAWS::Engine.new(
          game_data,
          @interface,
          **engine_options,
        )
        install_remote_debugger
        @engine.stepping = false if @debug_mode
        @started = false
        @last_picture_location = nil
        @graphics_base_result = nil
        @awaiting_key = false
        @paused_events = []
        @startup_stage = :engine_start
        @debugger_active = false
        @debugger_context = { p: 0, b: 0, c: 0 }
        @waiting_for_line_input = false
        @pending_replay_reset_key = false
      end

      def start
        return drain_with_prompt if @started

        @started = true
        set_running(true)
        events = [Protocol.session_ready(
          session_id: id,
          game: @game_name,
          debug: @debug_output,
          remote_debug: @remote_debug,
          text_renderer: @text_renderer,
          graphics_mode: @graphics_mode,
          font_size: @font_size,
        )]
        events << debug_status_event if @remote_debug
        events.concat(initial_charset_events)
        events.concat(drain_interface_events)

        if initial_splash_picture?
          events << decorate_picture_frame(initial_splash_picture_frame)
          if @interface.autoplay_active?
            events.concat(run_startup_title_text(clear_screen: true))
            return events
          end

          @startup_stage = :title_graphic
          @awaiting_key = true
          events << Protocol.input_request(mode: "key", prompt: "")
          return events
        end

        @startup_stage = :done
        events.concat(run_engine_startup)
        events.concat(picture_events_for_current_location(force: true)) unless screen_frame_event?(events)
        append_prompt_or_pause(events)
        events
      end

      def submit(input)
        return acknowledge_key if @awaiting_key
        return submit_debugger_command(input) if @debugger_active
        return start_debugger if debug_request?(input)
        return remote_debugger_paused_events if remote_debugger_paused?

        set_running(true) unless @engine.running?
        record_player_command(input)
        @interface.enqueue_input(input)
        settle_screen_input_origin
        @interface.output_text(input_echo_text(input), newline: true)
        catch(:desc_jump) do
          if @waiting_for_line_input
            @waiting_for_line_input = false
            run_queued_input_response
          else
            @engine.order_loop
          end
        end

        if @engine.running? && @engine.describe_flag
          events = drain_interface_events
          events.concat(run_description_after_turn)
          @waiting_for_line_input = @engine.running?
        else
          events = drain_interface_events
          events.concat(picture_events_for_current_location)
        end

        append_prompt_or_pause(events)
        events
      end

      def timeout
        return [] if @awaiting_key || @debugger_active
        return remote_debugger_paused_events if remote_debugger_paused?

        set_running(true) unless @engine.running?
        @interface.enqueue_timeout
        catch(:desc_jump) { @engine.order_loop }
        run_turn_until_input if @engine.running? && !@engine.describe_flag

        events = drain_interface_events
        if @engine.running? && @engine.describe_flag
          events.concat(run_description_after_turn)
        else
          events.concat(picture_events_for_current_location)
        end

        append_prompt_or_pause(events)
        events
      end

      def submit_key(key)
        return [] unless @awaiting_key
        return remote_debugger_paused_events if remote_debugger_paused?

        return reset_after_replay_exit_key if @pending_replay_reset_key
        return acknowledge_key if paused_key_sequence_pending?
        return resolve_pending_quit_confirmation(key) if @interface.pending_quit_confirmation
        return resolve_pending_end_confirmation(key) if @interface.pending_end_confirmation
        return run_startup_title_text(clear_screen: true) if @startup_stage == :title_graphic

        acknowledge_key
      end

      def snapshot
        {
          "type" => "session.snapshot",
          "session_id" => id,
          "running" => @engine.running?,
          "location" => @engine.state.location,
          "turns" => @engine.state.turns,
          "debug_paused" => remote_debugger_paused?,
          "debug_stepping" => remote_debugger_stepping?,
          "debug_breakpoint" => remote_debugger_breakpoint,
        }
      end

      def debug_status_event
        return nil unless @debug_controller

        advance_remote_debugger_step
        state = @debug_controller.state
        Protocol.debug_status(
          paused: remote_debugger_paused?,
          stepping: remote_debugger_stepping?,
          breakpoint: state["breakpoint"],
        )
      end

      private

      def install_remote_debugger
        return unless @debug_controller_factory

        @debug_controller = @debug_controller_factory.call(@engine, id: @id, game_name: @game_name)
        @engine.debugger.remote_controller = @debug_controller
      end

      def apply_initial_text_attributes
        defaults = @game_data.fetch("defaults", {})
        paper_code = defaults.fetch("paper", 0).to_i
        ink_code = defaults.fetch("ink", 7).to_i

        paper = ColorUtils.spectrum_color_name(paper_code) || "black"
        ink = ColorUtils.spectrum_color_name(ink_code, contrast_against: ColorUtils::COLORS.fetch(paper, 0)) || "white"
        bright = defaults.fetch("bright", 0).to_i != 0
        flash = defaults.fetch("flash", 0).to_i != 0

        @interface.set_colors(ink: ink, paper: paper, bright: bright, flash: flash)
      end

      def initial_charset_events
        charsets = @game_data["charsets"]
        udgs = @game_data["udgs"]
        metadata = @game_data.dig("charsets", "metadata") || @game_data["charsets_metadata"]
        return [] unless charsets || udgs

        active = @interface.active_charset || @game_data.dig("defaults", "charset")
        [Protocol.screen_charset(active: active&.to_i, charsets: charsets, udgs: udgs, metadata: metadata)]
      end

      def drain_with_prompt
        events = drain_interface_events
        events << debug_status_event if @remote_debug
        append_prompt_or_pause(events)
        events
      end

      def remote_debugger_paused?
        @debug_controller&.paused? || false
      end

      def remote_debugger_stepping?
        @engine.respond_to?(:stepping) && @engine.stepping
      end

      def remote_debugger_breakpoint
        return nil unless @debug_controller

        @debug_controller.state["breakpoint"]
      end

      def remote_debugger_paused_events
        [debug_status_event, Protocol.input_request(mode: @awaiting_key ? "key" : "line", prompt: "")].compact
      end

      def advance_remote_debugger_step
        return unless @remote_debug
        return unless remote_debugger_stepping?
        return if remote_debugger_paused?
        return unless @engine.running?

        @interface.suspend_on_empty_input = true
        begin
          @engine.step_resume_after = remote_debugger_step_resume_point
          @debug_controller.with_nonblocking_breakpoints do
            catch(:remote_debug_pause) do
              catch(:desc_jump) { @engine.order_loop }
            end
          end
        rescue InputWait
          nil
        ensure
          @engine.step_resume_after = nil
          @interface.suspend_on_empty_input = false
        end
      end

      def remote_debugger_step_resume_point
        breakpoint = remote_debugger_breakpoint
        return nil unless breakpoint

        [
          breakpoint["process"].to_i,
          breakpoint["block"].to_i,
          breakpoint["condact"].to_i,
        ]
      end

      def run_description_if_needed
        return unless @engine.describe_flag

        catch(:desc_jump) { @engine.description_phase }
      end

      def run_turn_until_input
        @interface.suspend_on_empty_input = true
        waiting = false

        begin
          catch :desc_jump do
            if @engine.describe_flag
              @engine.description_phase
              return if @engine.consume_restart_request
              return unless @engine.running?
            end

            @engine.order_loop
          end
        rescue InputWait
          waiting = true
        ensure
          @interface.suspend_on_empty_input = false
          @waiting_for_line_input = waiting && @engine.running?
        end
      end

      def run_queued_input_response
        result = @engine.input_phase
        return unless @engine.running?

        case result
        when :timeout
          @engine.output_sysmess(35, newline: true)
        when :not_found
          @engine.output_sysmess(6, newline: true)
        else
          @engine.response_phase
        end
      end

      def run_startup_title_text(clear_screen: false)
        @startup_stage = :title_text
        @awaiting_key = false
        run_turn_until_input

        events = drain_interface_events
        events.unshift({ "type" => "screen.clear" }) if clear_screen
        events.concat(run_description_after_turn) if @engine.running? && @engine.describe_flag
        append_prompt_or_pause(events)
        events
      end

      def run_engine_startup
        run_turn_until_input
        events = drain_interface_events
        events.concat(run_description_after_turn) if @engine.running? && @engine.describe_flag
        events.concat(picture_events_for_current_location)
        events
      end

      def run_description_after_turn
        @interface.reset_screen_cursor if @interface.respond_to?(:reset_screen_cursor)
        catch(:desc_jump) { @engine.description_phase }
        events = @interface.drain_events
        events.unshift({ "type" => "text.clear" }) unless @engine.skip_clear_screen
        events = compose_location_picture_events(
          events,
          picture_events_for_current_location(force: !@engine.skip_clear_screen),
        )
        events = expand_screen_picture_events(events)

        if @engine.running?
          catch(:desc_jump) { @engine.run_process(2, mode: :automatic) }
          events.concat(drain_interface_events)
          events.concat(picture_events_for_current_location)
        end

        events
      end

      def picture_events_for_current_location(force: false)
        return [] unless graphics_enabled?

        location = @engine.state.location
        return [] if location.nil?
        return [] if !force && location == @last_picture_location
        return [] if location_description(location).strip.empty?
        return [] unless @graphics.picture_ids.include?(location)

        rendered = @graphics.render_picture(location)
        frame = rendered.frame
        return [] unless frame.fetch("pixels_set", 0).positive?

        @last_picture_location = location
        @graphics_base_result = rendered.render_result
        [decorate_picture_frame(frame)]
      rescue KeyError
        []
      end

      def compose_location_picture_events(events, picture_events)
        unless compose_location_text_on_screen?
          return events if picture_events.empty?
          return events_with_picture_before_text(events, picture_events)
        end

        existing_frame = events.find { |event| event["type"] == "screen.frame" }
        frame_source = picture_events.first || existing_frame
        frame, cursor = @screen_model.frame_with_text_window(
          frame_source,
          graphics_line: @interface.graphics_line,
          ink: @interface.colors[:ink],
          paper: @interface.colors[:paper],
        )
        return events + picture_events unless cursor

        pause_before_text = pause_before_location_text_after_frame?
        bottom_row = pause_before_text ? 22 : 23
        frame_inserted = false
        events_to_process = existing_frame ? events.reject { |e| e.equal?(existing_frame) } : events
        events_to_process.each_with_object([]) do |event, output|
          unless event["type"] == "text.append"
            output << event
            next
          end

          unless frame_inserted
            output << frame if frame
            output << Protocol.input_request(mode: "key", prompt: "") if pause_before_text
            frame_inserted = true
          end

          output.concat(
            @screen_model.append_paginated_text_events(
              event,
              colors: @interface.colors,
              bottom_row: bottom_row,
            ),
          )
        end.tap do |output|
          output << frame if frame && !frame_inserted
          if @interface.respond_to?(:continue_screen_text_at)
            if frame
              @interface.continue_screen_text_at(
                @screen_model.cursor.fetch(:row),
                @screen_model.cursor.fetch(:col),
              )
            elsif @interface.respond_to?(:screen_cursor) && @interface.screen_cursor
              @screen_model.continue_at(
                @interface.screen_cursor.fetch(:row),
                @interface.screen_cursor.fetch(:col),
              )
            end
          end
        end
      end

      def pause_before_location_text_after_frame?
        false
      end

      def compose_location_text_on_screen?
        @text_renderer == "spectrum"
      end

      def events_with_picture_before_text(events, picture_events)
        split_at = events.index { |event| event["type"] == "text.append" } || events.length
        events[0...split_at] + picture_events + events[split_at..]
      end

      def drain_interface_events
        expand_screen_picture_events(@interface.drain_events)
      end

      # Only PAWS PICTURE/drawstring events become rendered frames here. EXTERN
      # events are external BASIC/ML screen effects and intentionally remain as
      # metadata for the client/debugger instead of being treated as drawings.
      def expand_screen_picture_events(events)
        base_result = @graphics_base_result

        events.flat_map do |event|
          if event["type"] == "screen.clear"
            @graphics_base_result = nil
            base_result = nil
            next event
          end
          unless event["type"] == "screen.picture"
            next event
          end
          next [] unless graphics_enabled?

          picture_id = event.fetch("picture_id")
          rendered = @graphics.render_picture(picture_id, full_screen: true, base_result: base_result)
          base_result = rendered.render_result
          @graphics_base_result = rendered.render_result
          decorate_picture_frame(rendered.frame)
        rescue KeyError
          event
        end
      end

      def decorate_picture_frame(frame)
        return frame unless @ai_graphics
        return frame if @text_renderer == "spectrum"

        @ai_graphics.decorate_frame(frame, description: location_description(frame.fetch("picture_id")))
      end

      def location_description(location_id)
        location = @game_data.fetch("locations", []).find { |entry| entry.fetch("id", nil).to_i == location_id.to_i }
        location ? TextMarkup.strip_tags(location.fetch("description", "").to_s) : ""
      end

      def screen_frame_event?(events)
        events.any? { |event| event["type"] == "screen.frame" }
      end

      def initial_splash_picture?
        return false unless graphics_enabled?
        return false if startup_defers_to_external_screen?
        return false if startup_process_draws_initial_picture?

        @engine.state.location.zero? && !initial_splash_picture_frame.nil?
      end

      def startup_defers_to_external_screen?
        @startup_defers_to_external_screen ||= startup_entries_for_initial_location.any? do |entry|
          condacts = entry.fetch("condacts", [])
          condact_name(condacts[1] || {}) == "ANYKEY" &&
            condact_name(condacts[2] || {}) == "EXTERN"
        end
      end

      def startup_process_draws_initial_picture?
        @startup_process_draws_initial_picture ||= begin
          startup_entries_for_initial_location.any? do |entry|
            entry.fetch("condacts", []).any? { |condact| condact_name(condact) == "PICTURE" }
          end
        end
      end

      def startup_entries_for_initial_location
        startup_process_entries.select { |entry| startup_entry_for_initial_location?(entry) }
      end

      def startup_entry_for_initial_location?(entry)
        first_condact = entry.fetch("condacts", []).first
        first_condact &&
          condact_name(first_condact) == "AT" &&
          condact_params(first_condact).first.to_i.zero?
      end

      def condact_name(condact)
        condact["name"] || condact[:name]
      end

      def condact_params(condact)
        condact["params"] || condact[:params] || []
      end

      def startup_process_entries
        processes = @engine.game_data_repository["processes"] || []
        process_list = processes.is_a?(Hash) ? processes.values : processes

        process_list.flat_map { |process| process.fetch("entries", []) }
      end

      def initial_splash_picture_frame
        @initial_splash_picture_frame ||= begin
          frame = @graphics.frame_for_picture(0, full_screen: true)
          frame.fetch("pixels_set", 0).positive? ? frame : nil
        rescue KeyError
          nil
        end
      end

      def settle_screen_input_origin
        return unless compose_location_text_on_screen?
        return unless @screen_input_origin
        return unless @interface.respond_to?(:continue_screen_text_at)

        origin = @screen_input_origin
        @screen_input_origin = nil
        start_row = @screen_model.respond_to?(:text_window_start_row) ? @screen_model.text_window_start_row : nil
        if start_row.nil? || start_row <= 0 || !firfurcio_arrow_prompt?
          @screen_model.continue_at(origin.fetch(:row), origin.fetch(:col)) if @screen_model.text_window_active?
          @interface.continue_screen_text_at(origin.fetch(:row), origin.fetch(:col))
          return
        end

        scroll_lines = [origin.fetch(:row).to_i - start_row.to_i, 0].max
        if scroll_lines.positive?
          @interface.events << Protocol.screen_scroll(lines: scroll_lines)
          @screen_model.continue_at(start_row, origin.fetch(:col))
          @interface.continue_screen_text_at(start_row, origin.fetch(:col))
        else
          @screen_model.continue_at(origin.fetch(:row), origin.fetch(:col)) if @screen_model.text_window_active?
          @interface.continue_screen_text_at(origin.fetch(:row), origin.fetch(:col))
        end
      end

      def prompt_event(prompt = nil)
        prompt ||= @engine.get_prompt_text
        origin = @screen_input_origin
        Protocol.input_request(
          mode: "line",
          prompt: prompt,
          screen_row: origin && origin[:row],
          screen_col: origin && origin[:col],
          input_style: line_input_text_style,
          cursor_style: line_input_cursor_style,
          cursor_glyph: line_input_cursor_glyph,
        )
      end

      def input_echo_text(input)
        style = style_tags(line_input_text_style.reject { |key, _value| key == "charset" })
        reset = style.empty? ? "" : default_text_style_reset
        return "#{style}#{input}#{reset}" if compose_location_text_on_screen?

        "#{style}> #{input}#{reset}"
      end

      def paused_key_sequence_pending?
        @paused_events.any? { |event| event["type"] == "input.request" && event["mode"] == "key" }
      end

      def acknowledge_key
        @awaiting_key = false
        @startup_stage = :done if @startup_stage == :title_text
        events = @paused_events
        @paused_events = []

        return events if pause_on_key_request(events)
        return events if events.any? { |event| event["type"] == "input.request" && event["mode"] == "line" }

        if @engine.running? && @engine.describe_flag
          events.concat(run_description_after_turn)
        else
          events.concat(picture_events_for_current_location)
        end

        append_prompt_or_pause(events)
        events
      end

      def set_running(value)
        @engine.instance_variable_set(:@running, value)
      end

      def graphics_enabled?
        @graphics_mode != "disabled"
      end

      def debug_request?(input)
        !@remote_debug && @debug_mode && input.to_s.strip.downcase == "!debug"
      end

      def start_debugger
        @interface.output_text("> !debug", newline: true)
        @debugger_active = true
        @debugger_context = {
          p: @engine.runner.current_pid,
          b: @engine.runner.current_b_idx,
          c: @engine.runner.current_c_idx,
        }
        events = run_debugger_repl(reason: "Manual request")
        events
      end

      def submit_debugger_command(input)
        @interface.output_text("> #{input}", newline: true)
        keep_debugging = @engine.debugger.handle_repl_input(input, **@debugger_context)

        if !keep_debugging && @engine.stepping && @engine.running?
          return run_debugger_step
        end

        @debugger_active = keep_debugging && @engine.running?

        debugger_prompt if @debugger_active
        events = drain_interface_events
        append_prompt_or_pause(events) unless @debugger_active
        events
      end

      def run_debugger_step
        run_debugger_execution_slice
        events = drain_interface_events
        append_prompt_or_pause(events) unless @debugger_active
        events
      end

      def run_debugger_execution_slice
        @interface.suspend_on_empty_input = true
        wait_for_more = false

        begin
          @engine.step_resume_after = @debugger_context.values_at(:p, :b, :c) if @engine.stepping
          catch(:desc_jump) { @engine.order_loop }
        rescue InputWait
          wait_for_more = true
        ensure
          @engine.step_resume_after = nil unless wait_for_more
          @interface.suspend_on_empty_input = false
        end

        @debugger_context = wait_for_more ? last_step_context : current_debugger_context
        @debugger_active = wait_for_more && @engine.running?
      end

      def run_debugger_repl(reason:)
        @interface.suspend_on_empty_input = true
        wait_for_more = false

        begin
          @engine.breakpoint_reached(
            @engine.runner.current_pid,
            @engine.runner.current_b_idx,
            @engine.runner.current_c_idx,
            reason: reason,
          )
        rescue InputWait
          wait_for_more = true
        ensure
          @interface.suspend_on_empty_input = false
        end

        @debugger_context = current_debugger_context
        @debugger_active = wait_for_more && @engine.running?
        drain_interface_events
      end

      def last_step_context
        p, b, c = @engine.last_step_point || current_debugger_context.values_at(:p, :b, :c)
        { p: p, b: b, c: c }
      end

      def current_debugger_context
        {
          p: @engine.runner.current_pid,
          b: @engine.runner.current_b_idx,
          c: @engine.runner.current_c_idx,
        }
      end

      def debugger_prompt
        @interface.output_text(
          "\nDEBUG (f:flags, t:stack, p:code, s:step, b:break, c:cont, x:exit, ?:help) > ",
          newline: false,
        )
        @interface.events << Protocol.input_request(mode: "line", prompt: "")
      end

      def append_prompt_or_pause(events)
        if pause_on_key_request(events)
          return
        elsif @engine.running?
          if @interface.autoplay_active? && (command = @interface.next_autoplay_command)
            events.concat(submit(command))
            return
          end

          prompt = @engine.get_prompt_text
          append_screen_prompt(events, prompt)
          events << prompt_event(prompt)
          pause_on_key_request(events)
        end
      end

      def append_screen_prompt(events, prompt)
        return unless compose_location_text_on_screen?
        return unless @screen_model.text_window_active?

        if @interface.respond_to?(:screen_cursor) && @interface.screen_cursor
          @screen_model.continue_at(@interface.screen_cursor.fetch(:row), @interface.screen_cursor.fetch(:col))
        end
        pause_before_bottom_prompt(events)

        screen_prompt = screen_prompt_text(prompt)
        last_event = events.last
        if last_event && (
             (last_event["type"] == "screen.text" && last_event["text"].to_s.empty? && last_event["newline"] != false && last_event["col"].to_i.zero?) ||
             last_event["type"] == "screen.scroll"
           )
          if last_event["type"] == "screen.text"
            blank = events.pop
            @screen_model.continue_at(blank.fetch("row"), blank.fetch("col", 0))
            @interface.continue_screen_text_at(blank.fetch("row"), blank.fetch("col", 0)) if @interface.respond_to?(:continue_screen_text_at)
          end
          screen_prompt = screen_prompt.to_s.sub(/\A\n/, "")
        end

        event = @screen_model.append_text_event(
          { "type" => "text.append", "text" => screen_prompt, "newline" => false },
          colors: @interface.colors,
        )
        return unless event

        events << event
        prompt_row = @screen_model.cursor.fetch(:row)
        cursor_col = @screen_model.cursor.fetch(:col).to_i
        has_embedded_cursor = screen_prompt.include?("{glyph:144:") || screen_prompt.include?("{glyph:147:")
        input_col = has_embedded_cursor ? [cursor_col - 1, 0].max : cursor_col
        @screen_input_origin = {
          row: prompt_row,
          col: input_col,
        }
        if @interface.respond_to?(:continue_screen_text_at)
          @interface.continue_screen_text_at(
            @screen_model.cursor.fetch(:row),
            @screen_model.cursor.fetch(:col),
          )
        end
      end

      def pause_on_key_request(events)
        key_request_index = events.index { |event| event["type"] == "input.request" && event["mode"] == "key" }
        return false unless key_request_index

        if insert_spectrum_key_prompt?(events[0...key_request_index])
          key_request_index = remove_trailing_blank_bottom_newline(events, key_request_index)
          events.insert(key_request_index, spectrum_key_prompt_event)
          key_request_index += 1
        end

        @awaiting_key = true
        before_pause = events[0...key_request_index]
        pending_events = events[(key_request_index + 1)..] || []
        pending_events = hidden_key_before_location_description(pending_events, before_pause)
        @paused_events = pending_events_after_key_request(
          pending_events,
          keep_on_screen: keep_pending_startup_events_on_screen?(before_pause, pending_events),
        )
        events.slice!((key_request_index + 1)..)
        @interface.clear_key_request
        true
      end

      def remove_trailing_blank_bottom_newline(events, key_request_index)
        blank_index = events[0...key_request_index].rindex do |event|
          event["type"] == "screen.text" &&
            event["text"].to_s.empty? &&
            event["newline"] != false &&
            event["row"].to_i >= 23
        end
        return key_request_index unless blank_index

        events.delete_at(blank_index)
        key_request_index - 1
      end

      def keep_pending_startup_events_on_screen?(before_pause, pending_events)
        return false unless @text_renderer == "pc"
        return false unless pending_events.any? { |event| event["type"] == "input.request" && event["mode"] == "key" }

        before_pause.any? { |event| event["type"] == "screen.text" }
      end

      def hidden_key_before_location_description(pending_events, before_pause)
        return pending_events unless compose_location_text_on_screen?
        return pending_events unless @engine.state.turns.positive?
        return pending_events unless before_pause.any? { |event| event["type"] == "screen.text" }

        frame_index = pending_events.index { |event| event["type"] == "screen.frame" }
        return pending_events unless frame_index
        frame = pending_events.fetch(frame_index)
        return pending_events unless frame["picture_id"].to_i == @engine.state.location.to_i

        events = pending_events.dup
        next_event = events[frame_index + 1]
        if next_event && next_event["type"] == "input.request" && next_event["mode"] == "key"
          events.delete_at(frame_index + 1)
        end
        [Protocol.input_request(mode: "key", prompt: "")] + events
      end

      def pending_events_after_key_request(events, keep_on_screen:)
        return events unless keep_on_screen

        # Some startup screens print a second full-screen title text block after an
        # ANYKEY without another PRINTAT. Keep only the block before the next
        # ANYKEY on the screen plane, while later location prose still goes to
        # the transcript once the title stage is complete.
        next_key_request_index = events.index { |event| event["type"] == "input.request" && event["mode"] == "key" } || events.length
        events.each_with_index.map do |event, index|
          next event unless event["type"] == "text.append"
          next event unless index < next_key_request_index

          Protocol.screen_text(
            event.fetch("text", ""),
            row: 5,
            col: 0,
            newline: event.fetch("newline", true),
            ink: @interface.colors[:ink],
            paper: @interface.colors[:paper],
            bright: @interface.colors[:bright],
            flash: @interface.colors[:flash],
          )
        end
      end

      def insert_spectrum_key_prompt?(before_pause)
        return false unless compose_location_text_on_screen?
        return false unless @engine.state.turns.positive?
        return false unless @screen_model.text_window_active?
        return false unless before_pause.any? { |event| event["type"] == "screen.text" }
        return false if before_pause.any? { |event| event["type"] == "screen.frame" }
        return false if before_pause.any? { |event| event["type"] == "screen.text" && event["text"].to_s.include?("Pulsa tecla.") }

        true
      end

      def spectrum_key_prompt_event
        Protocol.screen_text(
          "Pulsa tecla.",
          row: 23,
          col: 20,
          newline: false,
          ink: @interface.colors[:ink],
          paper: @interface.colors[:paper],
          bright: @interface.colors[:bright],
          flash: @interface.colors[:flash],
        )
      end

      def pause_before_bottom_prompt(events)
        return unless firfurcio_arrow_prompt?

        row = @screen_model.cursor&.fetch(:row, 0).to_i
        location_frame_after_turn = @engine.state.turns.positive? && events.any? { |event| event["type"] == "screen.frame" }
        threshold = location_frame_after_turn ? 22 : 23
        return unless row >= threshold

        remove_last_blank_bottom_newline(events)
        events << Protocol.screen_text(
          "Pulsa tecla.",
          row: 23,
          col: 20,
          newline: false,
          ink: @interface.colors[:ink],
          paper: @interface.colors[:paper],
          bright: @interface.colors[:bright],
          flash: @interface.colors[:flash],
        )
        events << Protocol.input_request(mode: "key", prompt: "")
        events << Protocol.screen_text(
          " " * 32,
          row: 23,
          col: 0,
          newline: false,
          ink: @interface.colors[:ink],
          paper: @interface.colors[:paper],
          bright: @interface.colors[:bright],
          flash: @interface.colors[:flash],
        )
        events << Protocol.screen_scroll(lines: 1)
        @screen_model.continue_at(23, 0)
        @interface.continue_screen_text_at(23, 0) if @interface.respond_to?(:continue_screen_text_at)
      end

      def remove_last_blank_bottom_newline(events)
        blank_index = events.rindex do |event|
          event["type"] == "screen.text" &&
            event["text"].to_s.empty? &&
            event["newline"] != false &&
            event["row"].to_i >= 23
        end
        events.delete_at(blank_index) if blank_index
      end

      def screen_prompt_text(prompt)
        text = prompt.to_s
        if text.strip == ">"
          if firfurcio_arrow_prompt?
            style, reset = line_input_style_parts
            return "#{style}{glyph:144:?}#{reset}"
          elsif things_arrow_prompt?
            style, reset = line_input_style_parts
            return "#{style}{glyph:146:>}#{reset}"
          else
            style = style_tags(line_input_text_style)
            reset = style.empty? ? "" : default_text_style_reset
            return "#{style}>#{reset}"
          end
        end

        text.sub(/\n((?:\{[^}]+\})*) \z/) { "\n#{Regexp.last_match(1)}#{line_input_marker}" }
      end

      def firfurcio_arrow_prompt?
        @game_data.dig("udgs", "glyphs", "144") == [0, 240, 126, 255, 255, 126, 240, 0]
      end

      def things_arrow_prompt?
        @game_data.dig("udgs", "glyphs", "146") == [128, 64, 32, 16, 16, 32, 64, 128]
      end

      def line_input_marker(default_prompt: false)
        style, reset = line_input_style_parts
        return "#{style}{glyph:144:?}#{reset}" if default_prompt && firfurcio_arrow_prompt?

        marker = @game_data.dig("udgs", "glyphs", "146") ? "{glyph:146:?}" : ">"
        cursor = @game_data.dig("udgs", "glyphs", "147") ? "{glyph:147:_}" : "_"
        "#{style}#{marker}#{cursor}#{reset}"
      end

      def line_input_style_parts
        raw = @game_data.fetch("system_messages", [])[34].to_s
        tags = raw.scan(/\{[^}]+\}/).join
        reset = +""
        style = tags.gsub(/{flash:0}/i) { reset << Regexp.last_match(0); "" }
        if style.match?(/{[0-5]}/)
          reset << "{#{@game_data.dig("defaults", "charset") || 0}}"
        end
        [style, reset]
      end

      def line_input_text_style
        @line_input_text_style ||= parse_style_tags(@game_data.fetch("system_messages", [])[34].to_s).tap do |style|
          style.delete("charset")
        end
      end

      def line_input_cursor_style
        if firfurcio_arrow_prompt?
          style, = line_input_style_parts
          @line_input_cursor_style ||= parse_style_tags(style)
        else
          @line_input_cursor_style ||= line_input_text_style.merge("flash" => false)
        end
      end

      def line_input_cursor_glyph
        return 144 if firfurcio_arrow_prompt?
        return 147 if @game_data.dig("udgs", "glyphs", "147") == [0, 0, 0, 0, 0, 0, 0, 255]
        return 144 if @game_data.dig("udgs", "glyphs", "144") == [0, 0, 0, 0, 0, 0, 0, 255]

        nil
      end

      def parse_style_tags(text)
        style = {}
        text.to_s.scan(/\{(ink|paper|bright|flash):([a-z0-9]+)\}|\{([0-5])\}/i) do |key, value, charset|
          if charset
            style["charset"] = charset.to_i
            next
          end

          case key.downcase
          when "ink", "paper"
            style[key.downcase] = value.downcase
          when "bright", "flash"
            style[key.downcase] = value.to_i != 0
          end
        end
        style
      end

      def style_tags(style)
        return "" unless style && !style.empty?

        tags = +""
        tags << "{#{style["charset"]}}" if style.key?("charset")
        tags << "{ink:#{style["ink"]}}" if style["ink"]
        tags << "{paper:#{style["paper"]}}" if style["paper"]
        tags << "{bright:#{style["bright"] ? 1 : 0}}" if style.key?("bright")
        tags << "{flash:#{style["flash"] ? 1 : 0}}" if style.key?("flash")
        tags
      end

      def default_text_style_reset
        "{#{@game_data.dig("defaults", "charset") || 0}}{ink:#{@interface.colors[:ink]}}{paper:#{@interface.colors[:paper]}}{bright:#{@interface.colors[:bright] ? 1 : 0}}{flash:#{@interface.colors[:flash] ? 1 : 0}}"
      end

      def resolve_pending_end_confirmation(key)
        @awaiting_key = false
        @paused_events = []
        @interface.pending_end_confirmation = false
        @interface.clear_key_request

        if accepted_key?(key)
          reset_game_session
        else
          @pending_replay_reset_key = true
          @awaiting_key = true
          [
            { "type" => "text.clear" },
            { "type" => "screen.clear" },
            Protocol.input_request(mode: "key", prompt: ""),
          ]
        end
      end

      def resolve_pending_quit_confirmation(key)
        @awaiting_key = false
        @paused_events = []
        @interface.pending_quit_confirmation = false
        @interface.clear_key_request

        if accepted_key?(key)
          @engine.output_sysmess(13)
          key = @interface.wait_for_key("")
          if @interface.pending_key?(key)
            @interface.pending_end_confirmation = true
            events = drain_interface_events
            append_prompt_or_pause(events)
            events
          elsif accepted_key?(key)
            reset_game_session
          else
            @pending_replay_reset_key = true
            @awaiting_key = true
            [
              { "type" => "text.clear" },
              { "type" => "screen.clear" },
              Protocol.input_request(mode: "key", prompt: ""),
            ]
          end
        else
          @engine.runner.execution_context.mark_done
          events = drain_interface_events
          append_prompt_or_pause(events)
          events
        end
      end

      def accepted_key?(key)
        accepted = @engine.game_data.dig("system_messages", 30)
        accepted = accepted["text"] if accepted.is_a?(Hash)
        accepted = accepted.to_s.chars.first
        accepted = "s" if accepted.nil? || accepted.empty?
        key.to_s.downcase == accepted.downcase
      end

      def reset_after_replay_exit_key
        @pending_replay_reset_key = false
        @awaiting_key = false
        @interface.clear_key_request
        reset_game_session
      end

      def reset_game_session
        @last_picture_location = nil
        @graphics_base_result = nil
        @waiting_for_line_input = false
        @startup_stage = :done
        @engine.restart
        @engine.consume_restart_request

        events = [
          { "type" => "text.clear" },
          { "type" => "screen.clear" },
        ]
        events.concat(run_engine_startup)
        append_prompt_or_pause(events)
        events
      end

      def record_player_command(input)
        return unless @command_history

        @command_history.puts(input)
        @command_history.flush
      end

      def open_output_file(path)
        return nil if path.nil?

        File.open(path, "w")
      end

      def load_autoplay_commands(path, range: nil)
        return nil if path.nil?

        AutoplayScript.load(path, range: range)
      end

      def strip_tags(text)
        TextMarkup.strip_tags(text)
      end
    end
  end
end
