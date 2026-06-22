require "pastel"
require "tty-reader"
require_relative "autoplay_script"
require_relative "../utils/color_utils"
require_relative "../utils/text_markup"
require_relative "save_game_store"
require_relative "interface"

module PAWS
  # Terminal implementation of Interface.
  # It adapts PAWS output/input needs to STDIN/STDOUT, ANSI colors, and local save files.
  class CLIInterface < Interface
    def initialize(colors_enabled: false, save_store: SaveGameStore.new, command_history_path: nil, transcript_path: nil, autoplay_path: nil)
      @colors_enabled = colors_enabled
      @pastel = Pastel.new(enabled: colors_enabled)
      @reader = TTY::Reader.new
      @current_ink = "white"
      @current_paper = "black"
      @bright = false
      @input_buffer = ""
      @save_store = save_store
      @command_history = open_output_file(command_history_path)
      @transcript = open_output_file(transcript_path)
      @autoplay_commands = load_autoplay_commands(autoplay_path)
    end

    def output_text(text, newline: true)
      return if text.nil?
      return if !newline && TextMarkup.formatting_only?(text)

      output = @colors_enabled ? render_colored_text(text) : strip_tags(text)
      record_transcript_text(strip_tags(text) + (newline ? "\n" : ""))
      if newline
        puts output
      else
        print output
      end
    end

    def output_debug(message, level)
      prefix = "[DEBUG:#{level}] "
      if @colors_enabled
        # We only dim the prefix, allowing the message to have its own colors
        puts "#{@pastel.dim(prefix)}#{message}"
      else
        puts "#{prefix}#{message}"
      end
    end

    def get_player_input(timeout: nil, prompt: "> ")
      if autoplay_active?
        command = next_autoplay_command
        raise Interrupt if command.nil?

        output_prompt(prompt)
        puts command
        record_player_command(command)
        record_transcript_text("#{strip_tags(prompt)}#{command}\n")
        return command
      end

      input = get_input(timeout: timeout, prompt: prompt)
      record_player_command(input) if input.is_a?(String)
      record_transcript_text("#{strip_tags(prompt)}#{input}\n") if input.is_a?(String)
      input
    end

    def input_buffer_empty?
      @input_buffer.empty?
    end

    def colorize(text, *styles)
      return text unless @colors_enabled
      @pastel.decorate(text, *styles.map(&:to_sym))
    end

    # Semantic formatting helpers for debug logs (colored implementations)
    def fmt_id(id)
      colorize(id, :cyan, :bold)
    end

    def fmt_p(p)
      colorize("P#{p.to_s.rjust(3, "0")}", :cyan, :bold)
    end

    def fmt_b(b)
      colorize("B#{b.to_s.rjust(3, "0")}", :cyan)
    end

    def fmt_c(c)
      colorize("C#{c.to_s.rjust(3, "0")}", :cyan)
    end

    def fmt_flag(f)
      colorize("F#{f}", :magenta, :bold)
    end

    def fmt_val(v)
      colorize(v.to_s, :white, :bold)
    end

    def fmt_word(w)
      colorize("'#{w}'", :blue, :italic)
    end

    def fmt_condact(n)
      colorize(n, :yellow, :bold)
    end

    def get_input(timeout: nil, prompt: "> ")
      # Print the prompt plus any buffered input from a previous timeout.
      full_prompt = "#{prompt}#{@input_buffer}"
      output_prompt(full_prompt)

      # Without a TTY, simplify reading to avoid blocking loops.
      unless $stdin.tty?
        result = IO.select([$stdin], nil, nil, timeout)
        return :timeout unless result

        input = $stdin.gets
        if input.nil? # EOF
          raise Interrupt
        end
        return input.strip
      end

      loop do
        # Wait for input with timeout.
        effective_timeout = @input_buffer.empty? ? timeout : nil
        result = IO.select([$stdin], nil, nil, effective_timeout)

        unless result
          # On timeout, return while preserving @input_buffer.
          puts # Newline before the timeout message.
          return :timeout
        end

        # Use TTY::Reader to read one character/key.
        begin
          char = @reader.read_char
        rescue StandardError
          # If reading fails, for example EOF in some environments, exit.
          raise Interrupt
        end

        if char.nil? # EOF
          raise Interrupt
        end

        case char
        when "\r", "\n"
          # Enter: return the buffer and clear it.
          input = @input_buffer.dup
          @input_buffer = ""
          puts
          return input
        when "\u007F", "\b" # Backspace / Delete
          if @input_buffer.length > 0
            @input_buffer.slice!(-1)
            print "\b \b"
            $stdout.flush
          end
        when "\u0003", "\u0004" # Ctrl+C or Ctrl+D
          raise Interrupt
        else
          # Only simple printable characters.
          if char.is_a?(String) && char.length == 1 && char.match?(/[[:print:]]/)
            @input_buffer << char
            $stdout.flush
          end
        end
      end
    end

    def wait_for_key(prompt = "")
      if autoplay_active?
        output_prompt(prompt)
        puts
        record_transcript_text(strip_tags(prompt) + "\n")
        return " "
      end

      if @colors_enabled
        print render_colored_text(prompt)
      else
        print strip_tags(prompt)
      end
      $stdout.flush

      key = if $stdin.tty?
          @reader.read_keypress
        else
          # In pipes, read a full line to consume the newline.
          $stdin.gets&.chars&.first
        end

      if key.nil? # EOF
        raise Interrupt
      end

      puts # Newline after the key.
      key
    end

    def record_player_command(input)
      return unless @command_history && input.is_a?(String)

      @command_history.puts(input)
      @command_history.flush
    end

    def record_transcript_text(text)
      return unless @transcript

      @transcript.write(text.to_s)
      @transcript.flush
    end

    def flush_input_buffer
      # No-op: flushing causes problems with pipes.
    end

    def clear_screen
      system("clear") || system("cls")
    end

    def set_colors(ink: nil, paper: nil, bright: nil, flash: nil)
      @current_ink = ink if ink
      @current_paper = paper if paper
      @bright = bright unless bright.nil?
    end

    def update_status(**status)
      # No-op in CLI
    end

    def save_game(state)
      output_text("Nombre del fichero para grabar? ", newline: false)
      filename = gets&.strip
      return if filename.nil? || filename.empty?

      begin
        @save_store.save(filename, state)
        output_text("Partida grabada.")
      rescue StandardError => e
        output_text("Error al grabar: #{e.message}")
      end
    end

    def load_game(engine)
      output_text("Nombre del fichero para cargar? ", newline: false)
      filename = gets&.strip
      return if filename.nil? || filename.empty?

      unless @save_store.exist?(filename)
        output_text("El fichero no existe.")
        return
      end

      begin
        engine.state.deserialize(@save_store.load(filename))
        output_text("Partida cargada.")
        engine.request_description
      rescue StandardError => e
        output_text("Error al cargar: #{e.message}")
      end
    end

    private

    def output_prompt(prompt)
      if @colors_enabled
        print render_colored_text("{ink:#{@current_ink}}{paper:#{@current_paper}}{bright:#{@bright ? 1 : 0}}#{prompt}")
      else
        print strip_tags(prompt)
      end
      $stdout.flush
    end

    def open_output_file(path)
      return nil if path.nil?

      File.open(path, "w")
    end

    def load_autoplay_commands(path)
      return nil if path.nil?

      AutoplayScript.load(path)
    end

    def strip_tags(text)
      TextMarkup.strip_tags(text)
    end

    def render_colored_text(text)
      text = TextMarkup.render_layout_controls(TextMarkup.render_glyph_tags(text))
      parts = text.split(/(\{.*?\})/)
      rendered = ""

      # Use local copies for rendering this specific text
      # This prevents inline tags from permanently changing the interface state
      ink = @current_ink
      paper = @current_paper
      bright = @bright

      parts.each do |part|
        case part
        when /^\{ink:([a-z]+)\}$/i
          ink = $1
        when /^\{paper:([a-z]+)\}$/i
          paper = $1
        when /^\{bright:([0-1])\}$/i
          bright = ($1 == "1")
        when /^\{[a-z0-9,:]+\}$/i
          # Ignore other tags
        else
          rendered << apply_style(part, ink, paper, bright) unless part.empty?
        end
      end
      rendered
    end

    def apply_style(text, ink_name, paper_name, bright)
      ink = ColorUtils.to_ansi(ink_name)
      paper = ColorUtils.to_ansi(paper_name)

      # For now, simple pastel decoration
      # Pastel supports 'bright' colors by prefixing with 'bright_'
      full_ink_name = bright ? "bright_#{ink}" : ink

      styled = @pastel.decorate(text, full_ink_name.to_sym)
      styled = @pastel.decorate(styled, "on_#{paper}".to_sym) if paper != "black"
      styled
    end
  end
end
