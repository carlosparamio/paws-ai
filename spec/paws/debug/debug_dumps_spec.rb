# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine"
require "paws/debug/debug_dumps"

RSpec.describe PAWS::DebugDumps do
  let(:interface) { instance_double(PAWS::Interface, output_text: nil) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Start" }, { "description" => "Room" }],
      "messages" => ["Hello"],
      "system_messages" => [{ "text" => "System" }],
      "objects" => [{ "description" => "Key", "initially_at" => PAWS::GameState::LOC_CARRIED }],
      "vocabulary" => [{ "id" => 10, "word" => "LOOK", "type" => "verb", "type_id" => 0 }],
      "processes" => [
        { "id" => 0, "entries" => [
          { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "DONE", "params" => [] }] },
        ] },
      ],
      "connections" => [[1, [[10, 0]]]],
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }
  subject(:dumps) { described_class.new(engine) }

  before do
    allow(interface).to receive(:colorize) { |text, *| text }
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    allow(engine).to receive(:location_text).and_return("Room")
    allow(engine).to receive(:vocabulary_word).and_return("LOOK")
    allow(engine).to receive(:object_text).and_return("Key")
  end

  it "renders flag and engine state snapshots" do
    engine.state.set_flag(8, 42)

    dumps.dump_flag(8)
    dumps.dump_engine_info

    expect(interface).to have_received(:output_text).with(/F8\s+=\s+42/)
    expect(interface).to have_received(:output_text).with(/ENGINE INFO/)
  end

  it "renders process, object, vocabulary, and connection dumps" do
    dumps.dump_current_process(0, 1, 1)
    dumps.dump_objects(0)
    dumps.dump_vocabulary(10)
    dumps.dump_connections(1)

    expect(interface).to have_received(:output_text).with(/PROCESS 000/)
    expect(interface).to have_received(:output_text).with(/O0: Key \[At: Carried\]/)
    expect(interface).to have_received(:output_text).with(/LOOK\s+\(ID: 10/)
    expect(interface).to have_received(:output_text).with(/LOOK\s+\(10\) -> Location 0/)
  end
end
