# frozen_string_literal: true

module PAWS
  # Abstract base class representing the port for user-facing IO and platform services.
  # Subclasses must implement core abstract methods to define concrete IO behaviors
  # (e.g., CLIInterface for terminal-based IO, or other implementations for GUI/Web).
  #
  # Responsibilities:
  # - Acts as an abstract contract/port for text output, input capture, screen management, and game persistence.
  # - Provides default fallback implementation methods for unstyled/unstyled-fallback or optional behaviors.
  # - Implements default semantic formatting helpers (e.g. `fmt_*`) used by debug logs and engine state dumps.
  class Interface
    def output_text(text, newline: true)
      raise "Not implemented"
    end

    def colorize(text, *_styles)
      text
    end

    def get_input(timeout: nil, prompt: "> ")
      raise "Not implemented"
    end

    def get_player_input(timeout: nil, prompt: "> ")
      get_input(timeout: timeout, prompt: prompt)
    end

    def install_autoplay_commands(commands)
      @autoplay_commands = commands.dup
    end

    def autoplay_active?
      @autoplay_commands && !@autoplay_commands.empty?
    end

    def next_autoplay_command
      return nil unless autoplay_active?

      @autoplay_commands.shift
    end

    def input_buffer_empty?
      true
    end

    def wait_for_key(prompt = "")
      raise "Not implemented"
    end

    def record_player_command(_input)
      # Optional no-op hook for command-history capture.
    end

    def record_transcript_text(_text)
      # Optional no-op hook for transcript capture.
    end

    def flush_input_buffer
      # Optional no-op base hook
    end

    def clear_screen
      raise "Not implemented"
    end

    def set_colors(ink: nil, paper: nil, bright: nil, flash: nil)
      # Optional no-op base hook
    end

    def supports_screen_graphics?
      false
    end

    def show_picture(_picture_id)
      false
    end

    def show_external(_parameter)
      false
    end

    def print_at(_line, _column)
      false
    end

    def set_graphics_line(_line)
      false
    end

    def set_charset(charset)
      # Optional no-op base hook
    end

    def update_status(**status)
      # Optional no-op base hook
    end

    def output_debug(message, level)
      # Optional no-op base hook
    end

    def save_game(state)
      raise "Not implemented"
    end

    def load_game(engine)
      raise "Not implemented"
    end

    def stop
      # Optional no-op base hook
    end

    # Semantic formatting helpers for debug logs (uncolored fallbacks)

    def fmt_id(id)
      id.to_s
    end

    def fmt_p(p)
      "P#{p.to_s.rjust(3, "0")}"
    end

    def fmt_b(b)
      "B#{b.to_s.rjust(3, "0")}"
    end

    def fmt_c(c)
      "C#{c.to_s.rjust(3, "0")}"
    end

    def fmt_flag(f)
      "F#{f}"
    end

    def fmt_val(v)
      v.to_s
    end

    def fmt_word(w)
      "'#{w}'"
    end

    def fmt_condact(n)
      n.to_s
    end
  end
end
