# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine"
require "paws/debug/debug_state_commands"

RSpec.describe PAWS::DebugStateCommands do
  let(:interface) { instance_double(PAWS::Interface, output_text: nil) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Start" }, { "description" => "Room" }],
      "objects" => [{ "description" => "Key", "initially_at" => 0 }],
      "processes" => [],
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }
  subject(:commands) { described_class.new(engine) }

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
    allow(engine).to receive(:object_text).and_return("Key")
  end

  it "sets flags through the debugger write surface" do
    commands.set_flag(8, 20)

    expect(engine.state.get_flag(8)).to eq(20)
    expect(interface).to have_received(:output_text).with(/Flag F8 set to 20/)
  end

  it "jumps to a location and requests a fresh description" do
    commands.jump_to_location(1)

    expect(engine.state.location).to eq(1)
    expect(engine.describe_flag).to be true
    expect(interface).to have_received(:output_text).with(/Jumped to Location 1/)
  end

  it "moves objects using PAWS location references" do
    engine.state.location = 1

    commands.move_object(0, "here")

    expect(engine.state.object_at(0)).to eq(1)
    expect(interface).to have_received(:output_text).with(/moved to L1/)
  end

  it "sets engine verbosity" do
    commands.set_verbosity(3)

    expect(engine.verbosity).to eq(3)
    expect(interface).to have_received(:output_text).with(/Verbosity level set to 3/)
  end

  it "handles the long set command form" do
    commands.handle_set("F60=42")
    commands.handle_set("invalid")

    expect(engine.state.get_flag(60)).to eq(42)
    expect(interface).to have_received(:output_text).with(/Usage: F<n>=<v>/)
  end
end
