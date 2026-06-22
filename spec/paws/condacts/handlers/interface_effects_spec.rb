# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::InterfaceEffects do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:interface) { instance_double(PAWS::Interface) }
  let(:state) { instance_double(PAWS::GameState) }
  let(:engine) do
    instance_double(
      PAWS::Engine,
      interface: interface,
      state: state,
      skip_clear_screen: false,
    )
  end
  let(:unsupported_entries) { [] }
  let(:optional_entries) { [] }
  let(:sleep_calls) { [] }
  let(:bell_calls) { [] }

  before do
    allow(engine).to receive(:log)

    described_class.register(
      registry,
      engine,
      unsupported: ->(name, params, reason:) { unsupported_entries << { name: name, params: params, reason: reason }; :unsupported },
      optional_noop: ->(name, params, reason:) { optional_entries << { name: name, params: params, reason: reason }; :ok },
      sleeper: ->(seconds) { sleep_calls << seconds },
      bell: -> { bell_calls << :bell },
    )
  end

  it "routes text output condacts through the engine" do
    expect(engine).to receive(:output_message).with(7, newline: true)
    expect(engine).to receive(:output_message).with(8, newline: false)
    expect(engine).to receive(:output_sysmess).with(9, newline: false)
    expect(engine).to receive(:output_text).with("")

    expect(registry.call("MESSAGE", [7])).to eq(:ok)
    expect(registry.call("MES", [8])).to eq(:ok)
    expect(registry.call("SYSMESS", [9])).to eq(:ok)
    expect(registry.call("NEWLINE")).to eq(:ok)
  end

  it "prints flag values through the engine" do
    expect(state).to receive(:get_flag).with(12).and_return(34)
    expect(engine).to receive(:output_text).with("34")

    expect(registry.call("PRINT", [12])).to eq(:ok)
  end

  it "routes colors, charset, prompt, and screen mode to interface and state" do
    expect(interface).to receive(:set_colors).with(ink: "red")
    expect(interface).to receive(:set_colors).with(paper: "blue")
    expect(interface).to receive(:set_charset).with(2)
    expect(state).to receive(:set_flag).with(PAWS::GameState::FLAG_PROMPT, 5)
    expect(state).to receive(:set_flag).with(PAWS::GameState::FLAG_SCREEN_MODE, 1)

    expect(registry.call("INK", [2])).to eq(:ok)
    expect(registry.call("PAPER", [1])).to eq(:ok)
    expect(registry.call("CHARSET", [2])).to eq(:ok)
    expect(registry.call("PROMPT", [5])).to eq(:ok)
    expect(registry.call("MODE", [1, nil])).to eq(:ok)
  end

  it "handles keyboard, clear screen, pause, bell, and optional sound" do
    expect(engine).to receive(:output_sysmess).with(16, newline: false)
    expect(interface).to receive(:wait_for_key)
    expect(interface).to receive(:flush_input_buffer)
    expect(interface).to receive(:clear_screen)

    expect(registry.call("ANYKEY")).to eq(:ok)
    expect(registry.call("CLS")).to eq(:ok)
    expect(registry.call("PAUSE", [5])).to eq(:ok)
    expect(registry.call("PAUSE", [0])).to eq(:ok)
    expect(registry.call("BELL")).to eq(:ok)
    expect(registry.call("BEEP", [10, 5])).to eq(:ok)

    expect(sleep_calls).to eq([0.1, 5.12])
    expect(bell_calls).to eq([:bell])
    expect(optional_entries).to include(hash_including(name: "BEEP", params: [10, 5]))
  end

  it "reports platform-dependent display condacts as unsupported" do
    expect(registry.call("LINE", [1])).to eq(:unsupported)
    expect(registry.call("PRINTAT", [1, 2])).to eq(:unsupported)
    expect(registry.call("BORDER", [3])).to eq(:unsupported)
    expect(registry.call("PICTURE", [4])).to eq(:unsupported)
    expect(registry.call("GRAPHIC", [5])).to eq(:unsupported)
    expect(registry.call("EXTERN", [6])).to eq(:unsupported)
    expect(registry.call("COPYFB", [7, 8])).to eq(:unsupported)
    expect(registry.call("COPYBF", [9, 10])).to eq(:unsupported)

    expect(unsupported_entries.map { |entry| entry[:name] }).to eq(
      %w[LINE PRINTAT BORDER PICTURE GRAPHIC EXTERN COPYFB COPYBF]
    )
  end

  it "routes EXTERN to web screen-effect interfaces when graphics are available" do
    web_registry = PAWS::CondactRegistry.new
    allow(interface).to receive(:show_external).with(0).and_return(true)

    described_class.register(
      web_registry,
      engine,
      unsupported: ->(name, params, reason:) { unsupported_entries << { name: name, params: params, reason: reason }; :unsupported },
      optional_noop: ->(name, params, reason:) { optional_entries << { name: name, params: params, reason: reason }; :ok },
      sleeper: ->(seconds) { sleep_calls << seconds },
      bell: -> { bell_calls << :bell },
      capabilities: PAWS::RuntimeCapabilities.web,
    )

    expect(web_registry.call("EXTERN", [0])).to eq(:ok)
  end

  it "keeps copy protection as an explicit optional no-op" do
    expect(registry.call("PROTECT")).to eq(:ok)
    expect(optional_entries).to include(hash_including(name: "PROTECT", params: []))
  end
end
