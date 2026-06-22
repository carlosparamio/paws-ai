# frozen_string_literal: true

module PAWS
  # Shared helpers for PAWS text tags that are not terminal/browser specific.
  module TextMarkup
    GLYPH_TAG = /\{glyph:\d+:([^}]*)\}/i
    LINE_BREAK_CONTROL_RUN = /(?:\{6\})+/i
    SENTENCE_BREAK_START = /(?:\{(?:ink|paper|bright|flash):[^}]+\})*(?:[A-ZÁÉÍÓÚÑ¿¡]|\{glyph:\d+:[A-ZÁÉÍÓÚÑ¿¡][^}]*\})/

    def self.render_glyph_tags(text)
      text.to_s.gsub(GLYPH_TAG, '\1')
    end

    def self.render_layout_controls(text)
      text.to_s.gsub(LINE_BREAK_CONTROL_RUN, "\n")
    end

    def self.wrap_screen_text(text, initial_col:, width: 32)
      source = render_implicit_sentence_breaks(render_layout_controls(text)).delete("\r")
      result = +""
      pending = +""
      word = +""
      word_len = 0
      col = initial_col.to_i

      flush_word = lambda do
        next if word.empty?

        pending_len = visible_length(pending)
        if col.positive? && col + pending_len + word_len > width
          result << invisible_markup(pending)
          result << "\n"
          col = 0
        else
          result << pending
          col += pending_len
        end

        result << word
        col += word_len
        pending = +""
        word = +""
        word_len = 0
      end

      source.scan(/\{glyph:\d+:[^}]*\}|\{[^}]+\}|\n|./m).each do |token|
        if token == "\n"
          flush_word.call
          result << pending
          result << token
          pending = +""
          col = 0
        elsif (glyph_match = token.match(/\A\{glyph:\d+:([^}]*)\}\z/i))
          visible = glyph_match[1].to_s[0] || " "
          if visible.match?(/[ \t]/)
            flush_word.call
            pending << token
          else
            word << token
            word_len += 1
          end
        elsif token.start_with?("{") && token.end_with?("}")
          if word.empty?
            pending << token
          else
            word << token
          end
        elsif token.match?(/[ \t]/)
          flush_word.call
          pending << token
        else
          word << token
          word_len += 1
        end
      end

      flush_word.call
      result << pending
      result
    end

    def self.strip_tags(text)
      render_layout_controls(render_glyph_tags(text)).gsub(/\{[^}]+\}/, "")
    end

    def self.formatting_only?(text)
      strip_tags(text).match?(/\A[ \t]*\z/)
    end

    def self.visible_length(text)
      strip_tags(text).length
    end
    private_class_method :visible_length

    def self.invisible_markup(text)
      text.to_s.gsub(/[ \t]/, "")
    end
    private_class_method :invisible_markup

    def self.render_implicit_sentence_breaks(text)
      text.to_s.gsub(/(?<![.A-ZÁÉÍÓÚÑ])\.(?!\.)(?=#{SENTENCE_BREAK_START})/, ".\n")
    end
    private_class_method :render_implicit_sentence_breaks
  end
end
