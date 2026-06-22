# frozen_string_literal: true

module PAWS
  module Web
    # Small factory for the JSON messages exchanged by the future WebSocket
    # server and the browser client. Keeping this separate lets the first HTTP
    # prototype and the later WebSocket endpoint share the same event shapes.
    module Protocol
      module_function

      def session_ready(session_id:, game:, debug: false, remote_debug: false, text_renderer: "pc", graphics_mode: "original", font_size: nil)
        {
          "type" => "session.ready",
          "session_id" => session_id,
          "game" => game,
          "debug" => debug,
          "remote_debug" => remote_debug,
          "text_renderer" => text_renderer,
          "graphics_mode" => graphics_mode,
          "font_size" => font_size,
        }
      end

      def text_append(text, newline: true)
        {
          "type" => "text.append",
          "text" => text,
          "newline" => newline,
        }
      end

      def screen_text(text, row:, col:, newline: true, ink: nil, paper: nil, bright: nil, flash: nil)
        {
          "type" => "screen.text",
          "text" => text,
          "row" => row,
          "col" => col,
          "newline" => newline,
          "ink" => ink,
          "paper" => paper,
          "bright" => bright,
          "flash" => flash,
        }
      end

      def screen_charset(active:, charsets:, udgs: nil)
        event = {
          "type" => "screen.charset",
          "active" => active,
          "charsets" => charsets,
        }
        event["udgs"] = udgs if udgs
        event
      end

      def screen_charset_select(active:)
        {
          "type" => "screen.charset.select",
          "active" => active,
        }
      end

      def screen_scroll(lines: 1)
        {
          "type" => "screen.scroll",
          "lines" => lines,
        }
      end

      def input_request(mode: "line", timeout_ms: nil, prompt: "> ", screen_row: nil, screen_col: nil, input_style: nil, cursor_style: nil, cursor_glyph: nil)
        event = {
          "type" => "input.request",
          "mode" => mode,
          "timeout_ms" => timeout_ms,
          "prompt" => prompt,
        }
        event["screen_row"] = screen_row unless screen_row.nil?
        event["screen_col"] = screen_col unless screen_col.nil?
        event["input_style"] = input_style if input_style
        event["cursor_style"] = cursor_style if cursor_style
        event["cursor_glyph"] = cursor_glyph if cursor_glyph
        event
      end

      def error(message)
        {
          "type" => "error",
          "message" => message,
        }
      end

      def debug_status(paused:, breakpoint: nil, stepping: false)
        {
          "type" => "debug.status",
          "paused" => paused,
          "stepping" => stepping,
          "breakpoint" => breakpoint,
        }
      end
    end
  end
end
