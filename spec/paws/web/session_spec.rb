# frozen_string_literal: true

require "spec_helper"
require "paws/debug/remote_controller"
require "paws/game_data/extractor"
require "paws/web/session"
require "tempfile"

RSpec.describe PAWS::Web::Session do
  def event_text(events)
    events.filter_map { |event| event["text"] || event["message"] }.join("\n")
  end

  def rendered_text(events)
    events.each_with_object(+"") do |event, text|
      next unless event["type"] == "text.append"

      text << event["text"].to_s.gsub(/\{[^}]+\}/, "")
      text << "\n" if event["newline"]
    end
  end

  def advance_until_line_prompt(session, max_keys: 10)
    events = []
    max_keys.times do
      break if events.any? { |event| event["type"] == "input.request" && event["mode"] == "line" }

      events = session.submit_key(" ")
    end
    events
  end

  let(:game_data) do
    JSON.parse(File.read(File.expand_path("../../../games/sample.json", __dir__)))
  end

  it "steps from the web debugger without leaking the step command to the parser" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample", engine_options: { verbosity: 3, debug_mode: true })

    session.start
    session.submit_key(" ")
    session.submit_key(" ")

    debug_text = event_text(session.submit("!debug"))
    help_text = event_text(session.submit("?"))
    first_step_events = session.submit("s")
    first_step_text = event_text(first_step_events)
    second_step_text = event_text(session.submit("s"))
    third_step_text = event_text(session.submit("s"))

    expect(debug_text).to include("BREAKPOINT REACHED")
    expect(help_text).to include("s / step")
    expect(first_step_text).to include("BREAKPOINT REACHED [P002|B000|C000]")
    expect(second_step_text).to include("BREAKPOINT REACHED [P002|B001|C000]")
    expect(third_step_text).to include("BREAKPOINT REACHED [P002|B001|C001]")
    expect(first_step_text).not_to include("Espero instrucciones")
    expect(first_step_events).to include(hash_including("type" => "input.request", "mode" => "line"))
  end

  it "does not enable the manual web debugger unless the server session was created in debug mode" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample")

    session.start
    session.submit_key(" ")
    session.submit_key(" ")

    text = event_text(session.submit("!debug"))

    expect(text).not_to include("BREAKPOINT REACHED")
  end

  it "blocks web game input while the remote debugger is paused" do
    controller = nil
    factory = lambda do |engine, id:, game_name:|
      controller = PAWS::Debug::RemoteController.new(engine, id: id, game_name: game_name)
    end
    session = described_class.new(
      id: "test",
      game_data: game_data,
      game_name: "sample",
      engine_options: { debug_mode: true },
      debug_controller_factory: factory,
    )

    session.start
    advance_until_line_prompt(session)
    controller.execute("pause")

    blocked_events = session.submit("mirar")

    expect(blocked_events).to include(hash_including("type" => "debug.status", "paused" => true))
    expect(event_text(blocked_events)).not_to include("> mirar")
    expect(session.snapshot).to include("debug_paused" => true)

    controller.execute("s")
    stepping_event = session.debug_status_event

    expect(controller.paused?).to be(true)
    expect(session.snapshot).to include("debug_paused" => true, "debug_stepping" => false)
    expect(stepping_event).to include("type" => "debug.status", "paused" => true, "stepping" => false)
    expect(stepping_event.fetch("breakpoint")).to include("reason" => "Step")

    controller.execute("pause")
    controller.execute("c")
    resumed_events = session.submit("mirar")

    expect(event_text(resumed_events)).to include("> mirar")
    expect(session.snapshot).to include("debug_paused" => false)
  end

  it "announces debug output availability from server-side runtime options" do
    plain_session = described_class.new(id: "plain", game_data: game_data, game_name: "sample")
    verbose_session = described_class.new(id: "verbose", game_data: game_data, game_name: "sample", engine_options: { verbosity: 1 })
    debug_session = described_class.new(id: "debug", game_data: game_data, game_name: "sample", engine_options: { debug_mode: true })

    expect(plain_session.start).to include(hash_including("type" => "session.ready", "debug" => false))
    expect(verbose_session.start).to include(hash_including("type" => "session.ready", "debug" => true))
    expect(debug_session.start).to include(hash_including("type" => "session.ready", "debug" => true))
  end

  it "announces the selected web text renderer" do
    plain_session = described_class.new(id: "plain", game_data: game_data, game_name: "sample")
    spectrum_session = described_class.new(id: "spectrum", game_data: game_data, game_name: "sample", text_renderer: "spectrum")

    expect(plain_session.start.first).to include("type" => "session.ready", "text_renderer" => "pc")
    expect(spectrum_session.start.first).to include("type" => "session.ready", "text_renderer" => "spectrum")
  end

  it "announces graphics mode and PC font size" do
    session = described_class.new(
      id: "test",
      game_data: game_data,
      game_name: "sample",
      graphics_mode: "disabled",
      font_size: 24,
    )

    expect(session.start.first).to include(
      "type" => "session.ready",
      "graphics_mode" => "disabled",
      "font_size" => 24,
    )
  end

  it "can run with web graphics disabled while preserving textual output" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample", graphics_mode: "disabled")

    events = session.start

    expect(events).not_to include(hash_including("type" => "screen.frame"))
    expect(rendered_text(events)).to include("THINGS!")
    expect(events).to include(hash_including("type" => "input.request", "mode" => "key"))
  end

  it "keeps EXTERN events separate from PAWS picture frames" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample")
    extern = { "type" => "screen.extern", "parameter" => 0 }

    events = session.send(:expand_screen_picture_events, [extern])

    expect(events).to eq([extern])
    expect(events).not_to include(hash_including("type" => "screen.frame"))
  end

  it "decorates location frames when AI graphics are enabled" do
    enhancer = double("ai_graphics")
    allow(enhancer).to receive(:decorate_frame) do |frame, description:|
      frame.merge("ai_graphics" => { "state" => "pending", "description" => description })
    end
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample", ai_graphics: enhancer)

    session.start
    events = advance_until_line_prompt(session)
    frame = events.find { |event| event["type"] == "screen.frame" && event["picture_id"] == 22 }

    expect(frame.fetch("ai_graphics")).to include("state" => "pending")
  end

  it "emits initial text colours from game defaults" do
    game = game_data.merge("defaults" => { "ink" => 9, "paper" => 0, "bright" => 0, "flash" => 1 })
    session = described_class.new(id: "test", game_data: game, game_name: "sample")

    start_events = session.start

    expect(start_events).to include(
      hash_including(
        "type" => "screen.attributes",
        "ink" => "white",
        "paper" => "black",
        "bright" => false,
        "flash" => true,
      ),
    )
  end

  it "prints the parser prompt onto the Spectrum screen before requesting input" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample", text_renderer: "spectrum")

    session.start
    session.submit_key(" ")
    location_events = session.submit_key(" ")
    prompt_event = location_events.reverse.find { |event| event["type"] == "input.request" && event["mode"] == "line" }

    expect(prompt_event).to be
    expect(location_events).to include(
      hash_including(
        "type" => "screen.text",
        "text" => prompt_event.fetch("prompt").sub(/\n((?:\{[^}]+\})*) \z/) { "\n#{$1}{ink:yellow}{glyph:146:?}{glyph:147:_}" },
      ),
    )
  end

  it "does not scroll a bottom blank line before a visible Spectrum key prompt" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "test", text_renderer: "spectrum")
    session.instance_variable_get(:@engine).state.turns = 1
    session.instance_variable_get(:@screen_model).continue_at(17, 0)
    events = [
      { "type" => "screen.text", "text" => "texto final", "row" => 23, "col" => 0, "newline" => false },
      { "type" => "screen.text", "text" => "", "row" => 23, "col" => 26, "newline" => true },
      { "type" => "screen.text", "text" => "{ink:red}1", "row" => 6, "col" => 16, "newline" => false },
      { "type" => "input.request", "mode" => "key", "prompt" => "" },
    ]

    expect(session.send(:pause_on_key_request, events)).to be(true)

    expect(events).not_to include(hash_including("type" => "screen.text", "text" => "", "row" => 23))
    expect(events).to include(
      hash_including("type" => "screen.text", "text" => "texto final", "row" => 23),
      hash_including("type" => "screen.text", "text" => "{ink:red}1", "row" => 6),
      hash_including("type" => "screen.text", "text" => "Pulsa tecla.", "row" => 23, "col" => 20),
      hash_including("type" => "input.request", "mode" => "key"),
    )
  end

  it "does not scroll a bottom blank line before a bottom Spectrum pause prompt" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "test", text_renderer: "spectrum")
    session.instance_variable_get(:@engine).state.turns = 1
    session.instance_variable_get(:@screen_model).continue_at(24, 0)
    events = [
      { "type" => "screen.frame", "picture_id" => 4 },
      { "type" => "screen.text", "text" => "texto final", "row" => 23, "col" => 0, "newline" => false },
      { "type" => "screen.text", "text" => "", "row" => 23, "col" => 26, "newline" => true },
      { "type" => "screen.text", "text" => "{ink:red}1", "row" => 6, "col" => 16, "newline" => false },
    ]

    session.send(:pause_before_bottom_prompt, events)

    expect(events).not_to include(hash_including("type" => "screen.text", "text" => "", "row" => 23))
    expect(events).to include(
      hash_including("type" => "screen.text", "text" => "texto final", "row" => 23),
      hash_including("type" => "screen.text", "text" => "{ink:red}1", "row" => 6),
      hash_including("type" => "screen.text", "text" => "Pulsa tecla.", "row" => 23, "col" => 20),
      hash_including("type" => "input.request", "mode" => "key"),
      hash_including("type" => "screen.text", "text" => " " * 32, "row" => 23, "col" => 0),
      hash_including("type" => "screen.scroll", "lines" => 1),
    )
  end

  it "does not add a second blank line before a Spectrum prompt after blank screen text" do
    previous_seed = srand(3)
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample", text_renderer: "spectrum")

    session.start
    session.submit_key(" ")
    location_events = session.submit_key(" ")
    prompt_screen_event = location_events.reverse.find { |event| event["type"] == "screen.text" && event["text"].to_s.include?("Es tu turno.") }

    expect(prompt_screen_event).to include(
      "row" => 19,
      "col" => 0,
      "text" => "\nEs tu turno.\n{ink:yellow}{glyph:146:?}{glyph:147:_}",
    )
  ensure
    srand(previous_seed) if previous_seed
  end

  it "records web player commands" do
    file = Tempfile.new("paws-web-commands")
    session = described_class.new(
      id: "test",
      game_data: game_data,
      game_name: "sample",
      command_history_path: file.path,
    )

    session.start
    session.submit_key(" ")
    session.submit_key(" ")
    session.submit("i")

    expect(File.read(file.path)).to include("i\n")
  ensure
    file&.close!
  end

  it "records each web transcript prompt and command echo only once" do
    file = Tempfile.new("paws-web-transcript")
    session = described_class.new(
      id: "test",
      game_data: game_data,
      game_name: "sample",
      transcript_path: file.path,
    )

    session.start
    session.submit_key(" ")
    session.submit_key(" ")
    session.submit("i")

    transcript = File.read(file.path)
    expect(transcript).to include("> i\n")
    expect(transcript).not_to include("> > i")
  ensure
    file&.close!
  end

  it "shows paused ANYKEY screens before consuming a pending END replay answer" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample")
    interface = session.instance_variable_get(:@interface)
    interface.pending_end_confirmation = true
    session.instance_variable_set(:@awaiting_key, true)
    session.instance_variable_set(:@paused_events, [
      { "type" => "screen.text", "text" => "First pause" },
      { "type" => "input.request", "mode" => "key", "prompt" => "" },
      { "type" => "text.append", "text" => "Replay prompt", "newline" => true },
      { "type" => "input.request", "mode" => "key", "prompt" => "" },
    ])

    first_pause_events = session.submit_key(" ")
    second_pause_events = session.submit_key(" ")

    expect(first_pause_events).to include(hash_including("type" => "screen.text", "text" => "First pause"))
    expect(second_pause_events).to include(hash_including("type" => "screen.text", "text" => "Replay prompt"))
    expect(interface.pending_end_confirmation).to be true

    black_events = session.submit_key("n")

    expect(black_events).to include(hash_including("type" => "screen.clear"))
  end

  it "keeps web QUIT waiting for the confirmation key before deciding the turn" do
    session = described_class.new(id: "test", game_data: game_data, game_name: "sample")

    session.start
    session.submit_key(" ")
    session.submit_key(" ")

    quit_events = session.submit("fin")
    quit_text = rendered_text(quit_events)

    expect(quit_text).to include("seguro")
    expect(quit_events).to include(hash_including("type" => "input.request", "mode" => "key"))
    expect(quit_events).not_to include(hash_including("type" => "input.request", "mode" => "line"))

    cancel_events = session.submit_key("n")

    expect(session.snapshot["running"]).to be true
    expect(cancel_events).to include(hash_including("type" => "input.request", "mode" => "line"))
  end

  it "advances a PAWS timeout without recording an empty player command" do
    timeout_game = {
      "locations" => [{ "description" => "" }],
      "objects" => [],
      "messages" => [],
      "system_messages" => ["", "> ", nil, nil, nil, nil, "No entiendo", nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, ""],
      "connections" => [],
      "vocabulary" => [],
      "processes" => [
        { "id" => 0, "entries" => [] },
        { "id" => 1, "entries" => [] },
        {
          "id" => 2,
          "entries" => [
            {
              "verb" => 1,
              "verb_name" => "*",
              "noun" => 1,
              "noun_name" => "*",
              "condacts" => [
                { "name" => "TIMEOUT", "params" => [] },
                { "name" => "MESSAGE", "params" => [0] },
                { "name" => "DONE", "params" => [] },
              ],
            },
          ],
        },
      ],
      "defaults" => {},
    }
    timeout_game["messages"][0] = "timeout fired"
    file = Tempfile.new("paws-web-timeout-commands")
    session = described_class.new(
      id: "test",
      game_data: timeout_game,
      game_name: "timeout",
      command_history_path: file.path,
    )
    engine = session.instance_variable_get(:@engine)
    engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH, 1)
    engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 1)

    events = session.timeout

    expect(rendered_text(events)).to include("timeout fired")
    expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(129)
    expect(File.read(file.path)).to eq("")
  ensure
    file&.close!
  end
end
