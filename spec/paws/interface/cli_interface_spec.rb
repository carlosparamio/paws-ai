# frozen_string_literal: true

require "spec_helper"
require "paws/interface/cli_interface"
require "paws/utils/color_utils"
require "json"
require "stringio"
require "tempfile"

RSpec.describe PAWS::CLIInterface do
  let(:interface) { described_class.new(colors_enabled: false) }
  let(:interface_colored) { described_class.new(colors_enabled: true) }

  describe "#output_text" do
    it "strips tags when colors are disabled" do
      expect { interface.output_text("Hello {ink:red}World") }.to output("Hello World\n").to_stdout
    end

    it "renders colored text when colors are enabled" do
      expect { interface_colored.output_text("Hello {ink:red}World") }.to output(/\e\[31mWorld/).to_stdout
    end

    it "supports newline: false" do
      expect { interface.output_text("Hello", newline: false) }.to output("Hello").to_stdout
    end

    it "suppresses inline formatting-only padding" do
      expect { interface.output_text("{paper:blue}     ", newline: false) }.not_to output.to_stdout
    end
  end

  describe "history and autoplay files" do
    it "records visible transcript text" do
      file = Tempfile.new("paws-transcript")
      interface = described_class.new(transcript_path: file.path)

      expect {
        interface.output_text("Hola {ink:red}mundo", newline: true)
      }.to output("Hola mundo\n").to_stdout

      expect(File.read(file.path)).to eq("Hola mundo\n")
    ensure
      file&.close!
    end

    it "records real player commands" do
      file = Tempfile.new("paws-commands")
      interface = described_class.new(command_history_path: file.path)

      interface.record_player_command("norte")

      expect(File.read(file.path)).to eq("norte\n")
    ensure
      file&.close!
    end

    it "feeds autoplay commands only through player input and auto-accepts key pauses" do
      file = Tempfile.new("paws-autoplay")
      file.write("norte\nmirar\n")
      file.close
      history = Tempfile.new("paws-autoplay-history")
      history.close
      interface = described_class.new(autoplay_path: file.path, command_history_path: history.path)

      expect { expect(interface.wait_for_key("Pulsa")).to eq(" ") }.to output("Pulsa\n").to_stdout
      expect { expect(interface.get_player_input(prompt: "> ")).to eq("norte") }.to output("> norte\n").to_stdout
      expect { expect(interface.get_player_input(prompt: "> ")).to eq("mirar") }.to output("> mirar\n").to_stdout
      expect(File.read(history.path)).to eq("norte\nmirar\n")
      expect(interface.autoplay_active?).to be false
    ensure
      file&.close!
      history&.close!
    end
  end

  describe "#output_debug" do
    it "outputs debug message with prefix" do
      expect {
        interface.output_debug("test message", 1)
      }.to output("[DEBUG:1] test message\n").to_stdout
    end

    it "outputs dim prefix when colors are enabled" do
      pastel = Pastel.new(enabled: true)
      expected_output = "#{pastel.dim("[DEBUG:2] ")}colored msg\n"
      expect {
        interface_colored.output_debug("colored msg", 2)
      }.to output(expected_output).to_stdout
    end
  end

  describe "#colorize" do
    it "returns uncolored text if colors are disabled" do
      expect(interface.colorize("text", :red)).to eq("text")
    end

    it "returns pastel decorated text if colors are enabled" do
      pastel = Pastel.new(enabled: true)
      expected = pastel.decorate("text", :red, :bold)
      expect(interface_colored.colorize("text", :red, :bold)).to eq(expected)
    end
  end

  describe "#clear_screen" do
    it "calls system clear or cls" do
      expect(interface).to receive(:system).with("clear").and_return(true)
      expect {
        interface.clear_screen
      }.not_to output.to_stdout
    end
  end

  describe "#set_colors" do
    it "updates internal color state" do
      interface_colored.set_colors(ink: "red", paper: "blue", bright: true)

      allow($stdin).to receive(:tty?).and_return(false)
      allow(IO).to receive(:select).and_return([[$stdin]])
      allow($stdin).to receive(:gets).and_return("test\n")

      expect {
        interface_colored.get_input(prompt: "> ")
      }.to output(/\e\[44m\e\[91m> \e\[0m\e\[0m/).to_stdout
    end
  end

  describe "#get_input" do
    context "when not a TTY (piped input)" do
      before do
        allow($stdin).to receive(:tty?).and_return(false)
      end

      it "outputs the prompt without tags if colors disabled" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        allow($stdin).to receive(:gets).and_return("input\n")

        expect {
          interface.get_input(prompt: "> ")
        }.to output("> ").to_stdout
      end

      it "returns timeout if IO.select times out" do
        allow(IO).to receive(:select).and_return(nil)
        expect {
          expect(interface.get_input(timeout: 1)).to eq(:timeout)
        }.to output("> ").to_stdout
      end

      it "raises Interrupt on EOF (gets returns nil)" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        allow($stdin).to receive(:gets).and_return(nil)

        expect {
          expect { interface.get_input }.to raise_error(Interrupt)
        }.to output("> ").to_stdout
      end

      it "returns stripped input" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        allow($stdin).to receive(:gets).and_return("   cmd \n")

        expect {
          expect(interface.get_input).to eq("cmd")
        }.to output("> ").to_stdout
      end
    end

    context "when TTY is present" do
      before do
        allow($stdin).to receive(:tty?).and_return(true)
      end

      it "returns timeout if IO.select times out" do
        allow(IO).to receive(:select).and_return(nil)
        expect {
          expect(interface.get_input(timeout: 1)).to eq(:timeout)
        }.to output("> \n").to_stdout
      end

      it "reads characters using TTY::Reader until Enter is pressed" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_return("t", "e", "s", "t", "\n")

        expect {
          result = interface.get_input
          expect(result).to eq("test")
        }.to output(/> \n/).to_stdout
      end

      it "does not keep applying the first-character timeout after typing starts" do
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(IO).to receive(:select).and_return([[$stdin]], [[$stdin]])
        allow(reader_double).to receive(:read_char).and_return("a", "\n")

        expect(interface.get_input(timeout: 1.28)).to eq("a")
        expect(IO).to have_received(:select).with([$stdin], nil, nil, 1.28).once
        expect(IO).to have_received(:select).with([$stdin], nil, nil, nil).once
      end

      it "handles backspace" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_return("a", "b", "\b", "c", "\n")

        expect {
          result = interface.get_input
          expect(result).to eq("ac")
        }.to output("> \b \b\n").to_stdout
      end

      it "ignores non-printable characters" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_return("a", "\x01", "b", "\n")

        expect {
          result = interface.get_input
          expect(result).to eq("ab")
        }.to output(/> \n/).to_stdout
      end

      it "raises Interrupt on Ctrl+C" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_return("\u0003")

        expect {
          interface.get_input
        }.to output(/> /).to_stdout.and raise_error(Interrupt)
      end

      it "raises Interrupt on StandardError from reader" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_raise(StandardError)

        expect {
          interface.get_input
        }.to output(/> /).to_stdout.and raise_error(Interrupt)
      end

      it "raises Interrupt on EOF (nil char)" do
        allow(IO).to receive(:select).and_return([[$stdin]])
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_char).and_return(nil)

        expect {
          interface.get_input
        }.to output(/> /).to_stdout.and raise_error(Interrupt)
      end
    end
  end

  describe "#wait_for_key" do
    context "when not a TTY (piped)" do
      before do
        allow($stdin).to receive(:tty?).and_return(false)
      end

      it "prints prompt without tags and gets first char" do
        allow($stdin).to receive(:gets).and_return("y\n")
        expect {
          expect(interface.wait_for_key("{ink:red}Press key")).to eq("y")
        }.to output("Press key\n").to_stdout
      end

      it "raises Interrupt on EOF" do
        allow($stdin).to receive(:gets).and_return(nil)
        expect {
          interface.wait_for_key("Press key")
        }.to output("Press key").to_stdout.and raise_error(Interrupt)
      end
    end

    context "when TTY is present" do
      before do
        allow($stdin).to receive(:tty?).and_return(true)
      end

      it "prints colored prompt and uses TTY::Reader" do
        reader_double = instance_double("TTY::Reader")
        interface_colored.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_keypress).and_return("x")

        expect {
          expect(interface_colored.wait_for_key("Prompt")).to eq("x")
        }.to output(/\e\[.*Prompt.*\n/).to_stdout
      end

      it "raises Interrupt on EOF" do
        reader_double = instance_double("TTY::Reader")
        interface.instance_variable_set(:@reader, reader_double)

        allow(reader_double).to receive(:read_keypress).and_return(nil)

        expect {
          interface.wait_for_key("Prompt")
        }.to output("Prompt").to_stdout.and raise_error(Interrupt)
      end
    end
  end

  describe "#save_game and #load_game" do
    let(:state) { instance_double(PAWS::GameState, to_json: '{"loc":1}') }
    let(:engine) { instance_double(PAWS::Engine, state: instance_double(PAWS::GameState)) }

    it "saves game to file" do
      allow(interface).to receive(:gets).and_return("test_save")
      expect(File).to receive(:write).with("test_save.sav", '{"loc":1}')
      expect { interface.save_game(state) }.to output(/Partida grabada/).to_stdout
    end

    it "handles standard errors during save" do
      allow(interface).to receive(:gets).and_return("testsave")
      allow(File).to receive(:write).and_raise(StandardError.new("Disk full"))
      expect { interface.save_game(state) }.to output(/Error al grabar: Disk full/).to_stdout
    end

    it "aborts if filename is empty" do
      allow(interface).to receive(:gets).and_return("\n")
      expect(File).not_to receive(:write)
      expect { interface.save_game(state) }.to output("Nombre del fichero para grabar? ").to_stdout
    end

    it "loads game from file" do
      allow(interface).to receive(:gets).and_return("test_load")
      allow(File).to receive(:exist?).with("test_load.sav").and_return(true)
      allow(File).to receive(:read).with("test_load.sav").and_return('{"loc":1}')

      expect(engine.state).to receive(:deserialize).with({ loc: 1 })
      expect(engine).to receive(:request_description)

      expect { interface.load_game(engine) }.to output(/Partida cargada/).to_stdout
    end

    it "outputs error if file does not exist" do
      allow(interface).to receive(:gets).and_return("missing")
      allow(File).to receive(:exist?).with("missing.sav").and_return(false)
      expect { interface.load_game(engine) }.to output(/El fichero no existe/).to_stdout
    end

    it "handles JSON parsing or other errors" do
      allow(interface).to receive(:gets).and_return("corrupt")
      allow(File).to receive(:exist?).with("corrupt.sav").and_return(true)
      allow(File).to receive(:read).with("corrupt.sav").and_return("invalid json")

      expect { interface.load_game(engine) }.to output(/Error al cargar/).to_stdout
    end

    it "aborts if filename is empty" do
      allow(interface).to receive(:gets).and_return("\n")
      expect(File).not_to receive(:exist?)
      expect { interface.load_game(engine) }.to output("Nombre del fichero para cargar? ").to_stdout
    end
  end

  describe "#strip_tags (private)" do
    it "removes curly brace tags" do
      expect(interface.send(:strip_tags, "Test {tag} message {ink:red}")).to eq("Test  message ")
    end

    it "renders glyph placeholders before removing control tags" do
      expect(interface.send(:strip_tags, "m{glyph:45:ú}sica")).to eq("música")
    end
  end

  describe "#render_colored_text (private)" do
    it "processes ink tags" do
      result = interface_colored.send(:render_colored_text, "{ink:red}Red Text")
      expect(result).to include("\e[31m")
    end

    it "processes paper tags" do
      result = interface_colored.send(:render_colored_text, "{paper:blue}Blue Background")
      expect(result).to include("\e[44m")
      expect(result).to include("Blue Background")
    end

    it "renders glyph placeholders through their fallback character" do
      result = interface_colored.send(:render_colored_text, "m{glyph:45:ú}sica")
      expect(result).to include("música")
    end

    it "renders PAWS line-break controls before applying colour tags" do
      result = interface_colored.send(:render_colored_text, "{ink:yellow}Uno{6}{6}Dos")
      expect(result).to include("Uno\nDos")
    end

    it "processes bright tags" do
      result = interface_colored.send(:render_colored_text, "{bright:1}{ink:white}Bright White")
      expect(result).to include("Bright White")
    end
  end
end
