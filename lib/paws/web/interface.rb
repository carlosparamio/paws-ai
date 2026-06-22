# frozen_string_literal: true

require_relative "../interface/interface"
require_relative "../utils/text_markup"
require_relative "protocol"

module PAWS
  module Web
    class InputWait < StandardError; end

    # Event-collecting interface adapter for the web runtime.
    #
    # This is intentionally non-blocking: the current HTTP prototype can inspect
    # emitted events, and the later WebSocket session runner will flush them to
    # the browser.
    class Interface < PAWS::Interface
      PENDING_KEY = Object.new.freeze

      attr_reader :events, :colors, :graphics_line, :active_charset, :screen_cursor
      attr_accessor :pending_end_confirmation, :pending_quit_confirmation

      def initialize(transcript_path: nil, autoplay_keys: false, paginate_screen_text: false, persist_screen_cursor_after_process: false, graphics_enabled: true)
        @events = []
        @colors = {}
        @queued_lines = []
        @queued_keys = []
        @key_requested = false
        @suspend_on_empty_input = false
        @transcript = open_output_file(transcript_path)
        @autoplay_keys = autoplay_keys
        @screen_cursor = nil
        @screen_cursor_explicit = false
        @text_flow_cursor = nil
        @screen_active = false
        @active_charset = nil
        @paginate_screen_text = paginate_screen_text
        @persist_screen_cursor_after_process = persist_screen_cursor_after_process
        @graphics_enabled = graphics_enabled
      end

      attr_writer :suspend_on_empty_input

      def output_text(text, newline: true)
        clean_text = clean_text_control_codes(text)

        if @screen_cursor
          record_transcript_text(strip_tags(clean_text) + (newline ? "\n" : "")) unless !newline && TextMarkup.formatting_only?(clean_text)
          output_screen_text(clean_text, newline: newline)
          return
        end

        return if !newline && TextMarkup.formatting_only?(clean_text)

        record_transcript_text(strip_tags(clean_text) + (newline ? "\n" : ""))
        @events << Protocol.text_append(clean_text, newline: newline)
      end

      def output_debug(message, level)
        @events << {
          "type" => "debug.message",
          "level" => level,
          "message" => message,
        }
      end

      def clear_screen
        @events << { "type" => "text.clear" }
        @events << { "type" => "screen.clear" }
        if @persist_screen_cursor_after_process && @screen_active
          @screen_cursor = { row: 0, col: 0 }
          @screen_cursor_explicit = false
          @text_flow_cursor = @screen_cursor.dup
        else
          @screen_active = false
          @screen_cursor = nil
          @screen_cursor_explicit = false
          @text_flow_cursor = nil
        end
      end

      def set_colors(ink: nil, paper: nil, bright: nil, flash: nil)
        @colors[:ink] = ink if ink
        @colors[:paper] = paper if paper
        @colors[:bright] = bright unless bright.nil?
        @colors[:flash] = flash unless flash.nil?
        @events << {
          "type" => "screen.attributes",
          "ink" => @colors[:ink],
          "paper" => @colors[:paper],
          "bright" => @colors[:bright],
          "flash" => @colors[:flash],
        }
      end

      def set_charset(charset)
        @active_charset = charset.to_i
        @events << Protocol.screen_charset_select(active: @active_charset)
        true
      end

      def supports_screen_graphics?
        @graphics_enabled
      end

      def show_picture(picture_id)
        return true unless @graphics_enabled

        @screen_active = true
        @events << { "type" => "screen.picture", "picture_id" => picture_id }
        true
      end

      def show_external(parameter)
        return true unless @graphics_enabled

        @screen_active = true
        @events << { "type" => "screen.extern", "parameter" => parameter.to_i }
        true
      end

      def set_graphics_line(line)
        return true unless @graphics_enabled

        @graphics_line = line.to_i
        true
      end

      def print_at(line, col)
        return true unless @graphics_enabled

        @screen_cursor = { row: line.to_i, col: col.to_i }
        @screen_cursor_explicit = true
        true
      end

      def reset_screen_cursor
        @screen_cursor = nil
        @screen_cursor_explicit = false
        @text_flow_cursor = nil
      end

      def continue_screen_text_at(row, col = 0)
        @screen_active = true
        @screen_cursor = { row: row.to_i, col: col.to_i }
        @screen_cursor_explicit = false
        @text_flow_cursor = @screen_cursor.dup
      end

      def after_process_call
        if @screen_cursor_explicit
          if @persist_screen_cursor_after_process && @text_flow_cursor
            @screen_cursor = @text_flow_cursor.dup
            @screen_cursor_explicit = false
          else
            reset_screen_cursor
          end
          return
        end

        reset_screen_cursor unless @persist_screen_cursor_after_process
      end

      def get_input(timeout: nil, prompt: "> ")
        queued = @queued_lines.shift
        return queued if queued

        @events << Protocol.input_request(
          mode: "line",
          timeout_ms: timeout ? (timeout * 1000).to_i : nil,
          prompt: prompt,
        )
        raise InputWait if @suspend_on_empty_input

        nil
      end

      def wait_for_key(prompt = "")
        queued = @queued_keys.shift
        return queued if queued

        if @autoplay_keys || autoplay_active?
          record_transcript_text(strip_tags(prompt) + "\n")
          return " "
        end

        @key_requested = true
        @events << Protocol.input_request(mode: "key", prompt: prompt)
        PENDING_KEY
      end

      def pause(seconds)
        @events << {
          "type" => "screen.pause",
          "duration_ms" => (seconds.to_f * 1000).round,
        }
        true
      end

      def enqueue_input(input)
        @queued_lines << input.to_s
      end

      def enqueue_timeout
        @queued_lines << :timeout
      end

      def enqueue_key(key)
        @queued_keys << key.to_s
      end

      def save_game(_state)
        @events << Protocol.error("Save is not implemented in the web prototype yet")
        nil
      end

      def load_game(_engine)
        @events << Protocol.error("Load is not implemented in the web prototype yet")
        nil
      end

      def drain_events
        drained = @events.dup
        @events.clear
        drained
      end

      def key_requested?
        @key_requested
      end

      def clear_key_request
        @key_requested = false
      end

      def pending_key?(key)
        key.equal?(PENDING_KEY)
      end

      def record_transcript_text(text)
        return unless @transcript

        @transcript.write(text.to_s)
        @transcript.flush
      end

      def suppress_unsupported_warnings?
        true
      end

      private

      def open_output_file(path)
        return nil if path.nil?

        File.open(path, "w")
      end

      def clean_text_control_codes(text)
        text.to_s.delete("\u007F")
      end

      def strip_tags(text)
        TextMarkup.strip_tags(text)
      end

      def output_screen_text(text, newline:)
        wrapped = TextMarkup.wrap_screen_text(
          text,
          initial_col: @screen_cursor.fetch(:col),
          width: 32,
        )
        emit_screen_tokens(screen_tokens(wrapped))
        if newline
          @screen_cursor[:row] += 1
          @screen_cursor[:col] = 0
        end
        @text_flow_cursor = @screen_cursor.dup unless @screen_cursor_explicit
      end

      def paginate_screen_if_needed
        return unless @paginate_screen_text
        return unless @screen_cursor.fetch(:row) >= 24

        @events << Protocol.screen_scroll(lines: 1)
        @screen_cursor[:row] = 23
        @screen_cursor[:col] = 0
      end

      def emit_screen_tokens(tokens)
        chunk = +""
        row = @screen_cursor.fetch(:row)
        col = @screen_cursor.fetch(:col)

        tokens.each do |token|
          if token.fetch(:visible) && @screen_cursor[:col] >= 32
            flush_screen_chunk(chunk, row, col)
            chunk = +""
            @screen_cursor[:row] += 1
            @screen_cursor[:col] = 0
            paginate_screen_if_needed
            row = @screen_cursor.fetch(:row)
            col = @screen_cursor.fetch(:col)
          end

          if @paginate_screen_text && token.fetch(:visible) && @screen_cursor[:row] >= 24
            flush_screen_chunk(chunk, row, col)
            chunk = +""
            paginate_screen_if_needed
            row = @screen_cursor.fetch(:row)
            col = @screen_cursor.fetch(:col)
          end

          chunk << token.fetch(:text)

          if token.fetch(:newline)
            flush_screen_chunk(chunk, row, col)
            chunk = +""
            @screen_cursor[:row] += 1
            @screen_cursor[:col] = 0
            paginate_screen_if_needed
            row = @screen_cursor.fetch(:row)
            col = @screen_cursor.fetch(:col)
            next
          end

          @screen_cursor[:col] += 1 if token.fetch(:visible)
        end

        flush_screen_chunk(chunk, row, col)
      end

      def flush_screen_chunk(chunk, row, col)
        return if chunk.empty?

        @events << Protocol.screen_text(
          chunk,
          row: row,
          col: col,
          newline: false,
          ink: @colors[:ink],
          paper: @colors[:paper],
          bright: @colors[:bright],
          flash: @colors[:flash],
        )
      end

      def screen_tokens(text)
        text.to_s.delete("\r").scan(/\{[^}]+\}|\n|./m).map do |token|
          if token == "\n"
            { text: token, visible: false, newline: true }
          elsif token.match?(/\A\{glyph:\d+:[^}]*\}\z/i)
            { text: token, visible: true, newline: false }
          elsif token.start_with?("{") && token.end_with?("}")
            { text: token, visible: false, newline: false }
          else
            { text: token, visible: true, newline: false }
          end
        end
      end
    end
  end
end
