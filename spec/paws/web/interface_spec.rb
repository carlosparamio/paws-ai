# frozen_string_literal: true

require "spec_helper"
require "paws/web/interface"
require "tempfile"

RSpec.describe PAWS::Web::Interface do
  it "preserves PAWS colour tags for the browser renderer" do
    interface = described_class.new

    interface.output_text("Una linterna {ink:yellow}encendida{ink:green}.")

    expect(interface.drain_events).to include(
      hash_including(
        "type" => "text.append",
        "text" => "Una linterna {ink:yellow}encendida{ink:green}.",
      ),
    )
  end

  it "still removes non-printable PAWS control bytes" do
    interface = described_class.new

    interface.output_text("A\u007FB")

    expect(interface.drain_events).to include(
      hash_including("text" => "AB"),
    )
  end

  it "writes transcript text without PAWS tags" do
    file = Tempfile.new("paws-web-transcript")
    interface = described_class.new(transcript_path: file.path)

    interface.output_text("Hola {ink:yellow}mundo", newline: true)

    expect(File.read(file.path)).to eq("Hola mundo\n")
  ensure
    file&.close!
  end

  it "writes glyph placeholders as their fallback character in transcripts" do
    file = Tempfile.new("paws-web-transcript")
    interface = described_class.new(transcript_path: file.path)

    interface.output_text("m{glyph:45:ú}sica", newline: true)

    expect(File.read(file.path)).to eq("música\n")
  ensure
    file&.close!
  end

  it "suppresses inline formatting-only padding events" do
    interface = described_class.new

    interface.output_text("{paper:blue}     ", newline: false)

    expect(interface.drain_events).to be_empty
  end

  it "auto-continues key pauses when autoplay is active" do
    interface = described_class.new(autoplay_keys: true)

    expect(interface.wait_for_key("Pulsa")).to eq(" ")
    expect(interface.drain_events).to be_empty
  end

  it "can queue a PAWS input timeout for the engine" do
    interface = described_class.new

    interface.enqueue_timeout

    expect(interface.get_input(timeout: 1.28, prompt: "> ")).to eq(:timeout)
    expect(interface.drain_events).to be_empty
  end

  it "emits active screen charset changes" do
    interface = described_class.new

    expect(interface.set_charset(2)).to be true

    expect(interface.drain_events).to include(
      { "type" => "screen.charset.select", "active" => 2 },
    )
  end

  it "emits picture and positioned screen text events" do
    interface = described_class.new

    expect(interface.show_picture(28)).to be true
    expect(interface.print_at(5, 9)).to be true
    interface.output_text("AVENTURAS A.D.", newline: false)

    expect(interface.drain_events).to include(
      { "type" => "screen.picture", "picture_id" => 28 },
      hash_including(
        "type" => "screen.text",
        "row" => 5,
        "col" => 9,
        "text" => "AVENTURAS A.D.",
        "newline" => false,
      ),
    )
  end

  it "emits external screen effect events separately from pictures" do
    interface = described_class.new

    expect(interface.show_external(0)).to be true

    expect(interface.drain_events).to include(
      { "type" => "screen.extern", "parameter" => 0 },
    )
  end

  it "does not keep post-CLS text on the Spectrum screen without cursor persistence" do
    interface = described_class.new

    interface.show_picture(28)
    interface.clear_screen
    interface.output_text("Mensaje de Albstein", newline: true)

    events = interface.drain_events
    expect(events).to include(
      { "type" => "screen.clear" },
      hash_including(
        "type" => "text.append",
        "text" => "Mensaje de Albstein",
      ),
    )
    expect(events).not_to include(hash_including("type" => "screen.text", "text" => "Mensaje de Albstein"))
  end

  it "keeps post-CLS text on the Spectrum screen when cursor persistence is enabled" do
    interface = described_class.new(persist_screen_cursor_after_process: true)

    interface.show_picture(28)
    interface.clear_screen
    interface.output_text("Mensaje de Albstein", newline: true)

    expect(interface.drain_events).to include(
      { "type" => "screen.clear" },
      hash_including(
        "type" => "screen.text",
        "row" => 0,
        "col" => 0,
        "text" => "Mensaje de Albstein",
      ),
    )
  end

  it "keeps advancing the Spectrum cursor after newline screen text" do
    interface = described_class.new

    interface.show_picture(1)
    interface.print_at(17, 0)
    interface.output_text("Linea uno", newline: true)
    interface.output_text("Linea dos", newline: true)

    expect(interface.drain_events).to include(
      hash_including(
        "type" => "screen.text",
        "row" => 17,
        "col" => 0,
        "text" => "Linea uno",
        "newline" => false,
      ),
      hash_including(
        "type" => "screen.text",
        "row" => 18,
        "col" => 0,
        "text" => "Linea dos",
        "newline" => false,
      ),
    )
  end

  it "wraps positioned Spectrum text at word boundaries" do
    interface = described_class.new

    interface.show_picture(1)
    interface.print_at(12, 0)
    interface.output_text("Est{glyph:64:á}s dentro de la fabrica de hielo.", newline: false)

    events = interface.drain_events
    expect(events).to include(
      hash_including(
        "type" => "screen.text",
        "row" => 12,
        "col" => 0,
        "text" => "Est{glyph:64:á}s dentro de la fabrica de\n",
      ),
      hash_including(
        "type" => "screen.text",
        "row" => 13,
        "col" => 0,
        "text" => "hielo.",
      ),
    )
  end

  it "scrolls the Spectrum text window without an implicit key pause" do
    interface = described_class.new(paginate_screen_text: true)

    interface.show_picture(1)
    interface.print_at(23, 0)
    interface.output_text("> ex maleta", newline: true)
    interface.output_text("Respuesta larga", newline: true)

    events = interface.drain_events
    expect(events).not_to include(hash_including("type" => "screen.text", "text" => "Pulsa tecla."))
    expect(events).not_to include(hash_including("type" => "input.request", "mode" => "key"))
    expect(events).to include(
      { "type" => "screen.scroll", "lines" => 1 },
      hash_including(
        "type" => "screen.text",
        "row" => 23,
        "col" => 0,
        "text" => "Respuesta larga",
      ),
    )
  end

  it "does not pause before overflow when screen pagination is disabled" do
    interface = described_class.new

    interface.show_picture(1)
    interface.print_at(23, 0)
    interface.output_text("> ex maleta", newline: true)
    interface.output_text("Respuesta larga", newline: true)

    events = interface.drain_events
    expect(events).not_to include(hash_including("type" => "input.request", "mode" => "key"))
    expect(events).not_to include(hash_including("type" => "screen.scroll"))
    expect(events).to include(
      hash_including(
        "type" => "screen.text",
        "row" => 24,
        "col" => 0,
        "text" => "Respuesta larga",
      ),
    )
  end
end
