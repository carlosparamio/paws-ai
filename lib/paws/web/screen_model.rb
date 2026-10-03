# frozen_string_literal: true

require_relative "../utils/text_markup"
require_relative "graphics_presenter"
require_relative "protocol"

module PAWS
  module Web
    # Models the 256x192 Spectrum screen as PAWS sees it: 32 columns x 24 rows
    # of 8x8 cells, with an optional text window placed over or below graphics.
    #
    # Web rendering still chooses between PC and Spectrum glyphs, but cursor
    # placement and the graphics/text split belong here rather than in the DOM.
    class ScreenModel
      COLUMNS = 32
      ROWS = 24
      CELL_SIZE = 8

      attr_reader :cursor, :text_window_start_row

      def initialize
        reset_text_window
      end

      def reset_text_window
        @text_window_start_row = nil
        @cursor = nil
      end

      def text_window_active?
        !@text_window_start_row.nil?
      end

      def frame_with_text_window(frame, graphics_line:, ink:, paper:)
        if frame.nil?
          @text_window_start_row = 0
          @cursor = { row: 0, col: 0 }
          return [nil, @cursor.dup]
        end

        start_row = text_start_row(frame, graphics_line: graphics_line)
        return [frame, nil] unless start_row

        prepared = frame.dup
        prepared["visible_height"] = GraphicsPresenter::HEIGHT
        prepared["full_screen"] = true
        prepared["text_window_start_row"] = start_row
        prepared["text_window_ink"] = ink
        prepared["text_window_paper"] = paper

        @text_window_start_row = start_row
        @cursor = { row: start_row, col: 0 }

        [prepared, @cursor.dup]
      end

      def blank_frame_with_text_window(graphics_line: nil, ink: "white", paper: "black")
        start_row = graphics_line ? [graphics_line.to_i, 0].max : 0
        start_row = [start_row, ROWS - 1].min

        frame = {
          "type" => "screen.frame",
          "picture_id" => nil,
          "logical_width" => COLUMNS * CELL_SIZE,
          "logical_height" => ROWS * CELL_SIZE,
          "visible_height" => ROWS * CELL_SIZE,
          "full_screen" => true,
          "text_window_start_row" => start_row,
          "text_window_ink" => ink || "white",
          "text_window_paper" => paper || "black",
        }

        @text_window_start_row = start_row
        @cursor = { row: start_row, col: 0 }

        [frame, @cursor.dup]
      end

      def text_start_row(frame, graphics_line:)
        explicit_graphics_line = !graphics_line.nil?
        row = graphics_line
        row ||= (frame.fetch("visible_height").to_i + CELL_SIZE - 1) / CELL_SIZE
        row = [row.to_i, 0].max
        return nil if row >= ROWS
        return nil if !explicit_graphics_line && row * CELL_SIZE >= frame.fetch("visible_height").to_i

        row
      end

      def append_text_event(event, colors:)
        return nil unless @cursor

        text = TextMarkup.wrap_screen_text(
          event.fetch("text"),
          initial_col: @cursor.fetch(:col),
          width: COLUMNS,
        )
        screen_event = Protocol.screen_text(
          text,
          row: @cursor.fetch(:row),
          col: @cursor.fetch(:col),
          newline: event.fetch("newline", true),
          ink: colors[:ink],
          paper: colors[:paper],
          bright: colors[:bright],
          flash: colors[:flash],
        )
        advance_cursor(text, newline: event.fetch("newline", true))
        screen_event
      end

      def append_paginated_text_events(event, colors:, bottom_row:)
        return [] unless @cursor

        text = TextMarkup.wrap_screen_text(
          event.fetch("text"),
          initial_col: @cursor.fetch(:col),
          width: COLUMNS,
        )
        events = []
        row = @cursor.fetch(:row)
        col = @cursor.fetch(:col)
        chunk = +""
        chunk_row = row
        chunk_col = col

        flush_chunk = lambda do
          next if chunk.empty?

          events << Protocol.screen_text(
            chunk,
            row: chunk_row,
            col: chunk_col,
            newline: false,
            ink: colors[:ink],
            paper: colors[:paper],
            bright: colors[:bright],
            flash: colors[:flash],
          )
          chunk = +""
        end

        text.scan(/\{glyph:\d+:[^}]*\}|\{[^}]+\}|\n|./m).each do |token|
          visible_width = token == "\n" ? 0 : TextMarkup.strip_tags(token).length
          if visible_width.positive? && row >= bottom_row.to_i
            flush_chunk.call
            events << Protocol.input_request(mode: "key", prompt: "")
            events << Protocol.screen_text(
              " " * COLUMNS,
              row: ROWS - 1,
              col: 0,
              newline: false,
              ink: colors[:ink],
              paper: colors[:paper],
              bright: colors[:bright],
              flash: colors[:flash],
            )
            scroll_lines = pagination_scroll_lines(bottom_row.to_i)
            events << Protocol.screen_scroll(lines: scroll_lines)
            row = bottom_row.to_i - scroll_lines
            col = 0
            chunk_row = row
            chunk_col = col
          end

          chunk << token
          if token == "\n"
            row += 1
            col = 0
          else
            col += visible_width
          end
        end

        if event.fetch("newline", true)
          row += 1
          col = 0
        end

        flush_chunk.call
        @cursor = { row: row, col: col }
        events
      end

      def continue_at(row, col = 0)
        @text_window_start_row ||= row.to_i
        @cursor = { row: row.to_i, col: col.to_i }
      end

      def advance_cursor(text, newline:)
        return unless @cursor

        TextMarkup.strip_tags(text).each_char do |char|
          next if char == "\r"

          if char == "\n"
            newline_cursor
            next
          end

          newline_cursor if @cursor[:col] >= COLUMNS
          @cursor[:col] += 1
        end

        newline_cursor if newline
      end

      private

      def pagination_scroll_lines(bottom_row)
        start_row = @text_window_start_row || 0
        [bottom_row - start_row - 2, 1].max
      end

      def newline_cursor
        @cursor[:row] += 1
        @cursor[:col] = 0
        @cursor[:row] = ROWS - 1 if @cursor[:row] >= ROWS
      end
    end
  end
end
