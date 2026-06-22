# frozen_string_literal: true

require "spec_helper"
require "paws"

RSpec.describe PAWS::InputPhase do
  let(:interface) do
    instance_double(
      PAWS::CLIInterface,
      output_text: nil,
      output_debug: nil,
      set_colors: nil,
      input_buffer_empty?: true,
      colorize: ->(text, *) { text },
      fmt_word: ->(w) { w.to_s },
      fmt_val: ->(v) { v.to_s },
      fmt_flag: ->(f) { f.to_s },
      fmt_id: ->(id) { id.to_s },
      fmt_condact: ->(n) { n.to_s },
    )
  end

  let(:game_data) do
    {
      "locations" => [{ "id" => 1, "text" => "Room" }],
      "objects" => [],
      "messages" => [],
      "system_messages" => {
        1 => { "text" => "> " },
        6 => { "text" => "I cannot." },
        35 => { "text" => "Time passes." },
      },
      "connections" => {},
      "vocabulary" => [
        { "word" => "coger", "id" => 14, "type_id" => 0 },
        { "word" => "llave", "id" => 21, "type_id" => 2 },
        { "word" => "sur", "id" => 2, "type_id" => 2 },
      ],
      "processes" => {},
    }
  end

  let(:engine) { PAWS::Engine.new(game_data, interface) }

  describe "#call" do
    it "decrements per-input timer flags before parsing a phrase" do
      engine.state.set_flag(5, 10)
      allow(interface).to receive(:get_player_input).and_return("sur")

      described_class.new(engine).call

      expect(engine.state.get_flag(5)).to eq(9)
    end

    it "keeps queued phrases on the engine for NEWTEXT and legacy callers" do
      allow(interface).to receive(:get_player_input).and_return("coger llave y sur")

      described_class.new(engine).call

      expect(engine.phrase_queue).to eq(["sur"])
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14)
    end

    it "returns timeout without parsing when the interface times out" do
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 1)
      allow(interface).to receive(:get_player_input).and_return(:timeout)

      expect(described_class.new(engine).call).to eq(:timeout)
      expect(engine.phrase_queue).to be_empty
      expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(129)
    end

    it "clears a previous timeout marker when a real input line arrives" do
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 129)
      allow(interface).to receive(:get_player_input).and_return("sur")

      described_class.new(engine).call

      expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(1)
    end

    it "loops after a debug request and asks for another input" do
      engine.instance_variable_set(:@debug_enabled, true)
      allow(interface).to receive(:get_player_input).and_return("!debug", :timeout)
      allow(engine.debugger).to receive(:breakpoint_reached)

      expect(engine).to receive(:breakpoint_reached).with(any_args).and_call_original

      expect(described_class.new(engine).call).to eq(:timeout)
    end
  end

  describe "#clear_phrases" do
    it "clears the engine-owned phrase queue" do
      engine.replace_phrase_queue(["sur"])

      described_class.new(engine).clear_phrases

      expect(engine.phrase_queue).to be_empty
    end
  end
end
