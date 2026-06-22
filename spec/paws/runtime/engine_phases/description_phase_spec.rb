# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine"
require "paws/runtime/engine_phases/description_phase"

RSpec.describe PAWS::DescriptionPhase do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [
        { "description" => "Title" },
        { "description" => "Room" },
      ],
      "system_messages" => ["", nil, nil, nil, nil, nil, nil, nil, "Dark"],
      "objects" => [
        { "description" => "lamp", "initially_at" => PAWS::GameState::LOC_NOT_CREATED },
      ],
      "processes" => [
        { "id" => 0, "entries" => [] },
        { "id" => 1, "entries" => [] },
        { "id" => 2, "entries" => [] },
      ],
      "vocabulary" => [],
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }

  subject(:phase) { described_class.new(engine) }

  before do
    allow(interface).to receive(:set_colors)
    allow(interface).to receive(:clear_screen)
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:colorize) { |value, *_args| value.to_s }
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    engine.instance_variable_set(:@running, true)
    engine.state.location = 1
  end

  it "runs process 1 with wildcard logical sentence flags after describing" do
    expect(engine).to receive(:run_process).with(1, mode: :automatic)

    phase.call

    expect(engine.describe_flag).to be false
    expect(engine.done_flag).to be false
    expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(PAWS::ProcessRunner::WILDCARD_STAR)
    expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(PAWS::ProcessRunner::WILDCARD_STAR)
  end

  it "decrements description timers and emits darkness text while dark" do
    engine.state.set_flag(PAWS::GameState::FLAG_DARK, 1)
    engine.state.set_flag(2, 2)
    engine.state.set_flag(3, 2)
    engine.state.set_flag(4, 2)

    expect(interface).to receive(:output_text).with("Dark", hash_including(newline: true))

    phase.describe_location

    expect(engine.state.get_flag(2)).to eq(1)
    expect(engine.state.get_flag(3)).to eq(1)
    expect(engine.state.get_flag(4)).to eq(1)
  end
end
