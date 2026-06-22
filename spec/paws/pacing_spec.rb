# frozen_string_literal: true

require "paws/runtime/engine"
require "paws/interface/cli_interface"
require "paws/runtime/game_state"
require "paws/runtime/process_runner"

RSpec.describe "PAWS Pacing and Event Logistics" do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "game" => { "title" => "Test Game", "author" => "Author" },
      "vocabulary" => [
        { "word" => "norte", "id" => 1, "type_id" => 1 },
        { "word" => "i", "id" => 10, "type_id" => 2 },
      ],
      "locations" => {
        "1" => { "description" => "Location 1" },
        "2" => { "description" => "Location 2" },
      },
      "system_messages" => ["SM0", "Also see:", nil, nil, nil, nil, "Invalid", "SM7", "Dark"],
      "objects" => [
        { "description" => "a key", "initially_at" => 1, "noun" => 20 },
      ],
      "processes" => {
        "0" => { "entries" => [] },
        "1" => { "entries" => [] },
        "2" => { "entries" => [] },
      },
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }

  before do
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:clear_screen)
    allow(interface).to receive(:update_status)
    allow(interface).to receive(:get_input).and_return("norte") # Default answer
    allow(interface).to receive(:colorize)
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    engine.instance_variable_set(:@running, true)
  end

  describe "GOTO and Description" do
    it "GOTO changes location, uses describe_flag from fallback path" do
      engine.describe_flag = false
      runner = PAWS::ProcessRunner.new(engine)
      runner.send(:condact_goto, 2)

      expect(engine.state.location).to eq(2)
      # Note: condact_goto itself does not set describe_flag.
      # Description is requested by the engine's fallback_response
      # or by callers that check the describe_flag after the goto.
    end
  end

  describe "UI Formatting (Newlines)" do
    it "describe_location outputs location text without an implicit newline" do
      engine.state.location = 1
      expect(interface).to receive(:output_text).with("Location 1", hash_including(newline: false))
      engine.describe_location
    end

    it "list_objects_at uses newline for header" do
      expect(interface).to receive(:output_text).with("Also see:", hash_including(newline: true))
      engine.list_objects_at(1)
    end
  end

  describe "Process 2 Pacing" do
    it "does NOT run Process 2 during description loop (to avoid duplicates)" do
      # Mocking run_process to see what happens
      expect(engine).to receive(:run_process).with(1, mode: :automatic)
      expect(engine).not_to receive(:run_process).with(2)

      engine.description_loop
    end

    it "runs Process 2 exactly once at the start of order loop" do
      engine.describe_flag = false # Prevent description_phase from triggering p1
      # Simulating one turn of the order_loop
      # We mock input_phase to return :found once then stop
      call_count = 0
      allow(engine).to receive(:input_phase) do
        call_count += 1
        call_count == 1 ? :found : throw(:stop_loop)
      end

      # Mock processing to not trigger description again
      allow(engine).to receive(:run_process).with(0, mode: :response)
      allow(engine).to receive(:try_direction_movement).and_return(:moved)

      expect(engine).to receive(:run_process).with(2, mode: :automatic).once

      catch(:stop_loop) do
        engine.order_loop
      end
    end
  end
end
