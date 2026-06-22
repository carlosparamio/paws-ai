# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine"
require "paws/debug/debugger"
require "tempfile"

RSpec.describe PAWS::Debugger do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Loc 0" }, { "description" => "Loc 1" }],
      "messages" => ["Msg 0"],
      "system_messages" => ["SysMsg 0"] * 60,
      "objects" => [{ "description" => "Obj 0", "initially_at" => 1 }],
      "vocabulary" => [{ "id" => 10, "word" => "TOMA", "type" => 0 }],
      "processes" => [
        { "id" => 0, "entries" => [
          { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "DONE", "params" => [] }] },
        ] },
      ],
      "connections" => [[0, [[0, 1]]]],
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }
  subject(:debugger) { PAWS::Debugger.new(engine) }

  before do
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:colorize) { |text, *| text }
    allow(interface).to receive(:set_colors)
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    allow(engine).to receive(:location_text).and_return("Loc Name")
    allow(engine).to receive(:vocabulary_word).and_return("WORD")
    allow(engine).to receive(:object_text).and_return("OBJECT")
  end

  it "exposes dump commands as public API" do
    expect(debugger.public_methods).to include(
      :dump_engine_info,
      :dump_stack,
      :dump_breakpoints,
      :dump_current_process,
      :dump_locations,
      :dump_messages,
      :dump_system_messages,
      :dump_objects,
      :dump_vocabulary,
      :dump_connections,
      :dump_state
    )
  end

  describe "#breakpoint_reached" do
    it "displays breakpoint info and enters command loop" do
      # Provide 'c' to exit the loop immediately
      expect(interface).to receive(:get_input).and_return("c")

      debugger.breakpoint_reached(0, 1, 0)

      expect(interface).to have_received(:output_text).with(/🛑 BREAKPOINT REACHED/)
    end

    it "handles help command" do
      expect(interface).to receive(:get_input).and_return("?", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/Available commands/)
    end

    it "handles flag inspection" do
      engine.state.set_flag(8, 10)
      expect(interface).to receive(:get_input).and_return("f8", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/F8\s+=  10/)
    end

    it "handles flag modification" do
      expect(interface).to receive(:get_input).and_return("f8=20", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.get_flag(8)).to eq(20)
    end

    it "handles location jumping" do
      expect(interface).to receive(:get_input).and_return("l=1", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.location).to eq(1)
      expect(engine.describe_flag).to be true
    end

    it "handles object movement" do
      expect(interface).to receive(:get_input).and_return("o0=10", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.object_at(0)).to eq(10)
    end

    it "handles stack dump" do
      expect(interface).to receive(:get_input).and_return("t", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/STACK TRACE/)
    end

    it "handles code dump (p)" do
      expect(interface).to receive(:get_input).and_return("p", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/PROCESS 000/)
    end

    it "handles stepping (s)" do
      expect(interface).to receive(:get_input).and_return("s")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.stepping).to be true
    end

    it "handles stepping (step alias)" do
      expect(interface).to receive(:get_input).and_return("step")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.stepping).to be true
    end

    it "handles aborting (x)" do
      expect(interface).to receive(:get_input).and_return("x")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.abort_execution).to be true
    end

    it "handles quitting (q)" do
      expect(interface).to receive(:get_input).and_return("q")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.running?).to be false
    end

    it "handles breakpoint deletion" do
      engine.breakpoint_manager.parse_line("L10")
      expect(interface).to receive(:get_input).and_return("b del 0", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.breakpoint_manager.breakpoints[:locations]).to be_empty
    end

    it "handles various dump commands" do
      expect(interface).to receive(:get_input).and_return(
        "sf", "uf", "kuf", "e", "b", "l", "m", "sys", "o", "v", "con", "c"
      )
      debugger.breakpoint_reached(0, 1, 0)

      expect(interface).to have_received(:output_text).with(/SYSTEM FLAGS/)
      expect(interface).to have_received(:output_text).with(/ALL USER FLAGS/)
      expect(interface).to have_received(:output_text).with(/NAMED USER FLAGS/)
      expect(interface).to have_received(:output_text).with(/ENGINE INFO/)
      expect(interface).to have_received(:output_text).with(/ACTIVE BREAKPOINTS/)
      expect(interface).to have_received(:output_text).with(/LOCATIONS/)
      expect(interface).to have_received(:output_text).with(satisfy { |t| t =~ /--- MESSAGES ---/ && t !~ /SYSTEM/ })
      expect(interface).to have_received(:output_text).with(satisfy { |t| t =~ /--- SYSTEM MESSAGES ---/ })
      expect(interface).to have_received(:output_text).with(satisfy { |t| t =~ /--- OBJECTS ---/ })
      expect(interface).to have_received(:output_text).with(satisfy { |t| t =~ /--- VOCABULARY ---/ })
      expect(interface).to have_received(:output_text).with(satisfy { |t| t =~ /--- CONNECTIONS FOR/ })
    end

    it "handles verbosity setting command" do
      expect(interface).to receive(:get_input).and_return("vb=2", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.verbosity).to eq(2)
      expect(interface).to have_received(:output_text).with(/Verbosity level set to 2/)
    end

    it "queues ranged autoplay commands from the debugger without consuming key pauses" do
      file = Tempfile.new("paws-debug-autoplay")
      file.write("norte\nsur\nmirar\n")
      file.close

      expect(interface).to receive(:install_autoplay_commands).with(%w[sur mirar])
      expect(interface).to receive(:get_input).and_return("autoplay #{file.path} 2-3", "c")

      debugger.breakpoint_reached(0, 1, 0)

      expect(interface).to have_received(:output_text).with(/Autoplay queued 2 command/)
    ensure
      file&.close!
    end

    it "handles set command for flags" do
      expect(interface).to receive(:get_input).and_return("set f60=42", "set invalid", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.get_flag(60)).to eq(42)
      expect(interface).to have_received(:output_text).with(/Usage: F<n>=<v>/)
    end

    it "handles all flags dump (f)" do
      expect(interface).to receive(:get_input).and_return("f", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/ALL FLAGS/)
    end

    it "handles single item regex dump commands" do
      expect(interface).to receive(:get_input).and_return("l1", "m0", "sys0", "o0", "v10", "con", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/L1: Loc 1/)
      expect(interface).to have_received(:output_text).with(/M0: Msg 0/)
      expect(interface).to have_received(:output_text).with(/SM0: SysMsg 0/)
      expect(interface).to have_received(:output_text).with(/O0: OBJECT \[At: Location 1\]/)
      expect(interface).to have_received(:output_text).with(/TOMA\s+\(ID: 10/)
    end

    it "handles unknown commands" do
      expect(interface).to receive(:get_input).and_return("invalid_command", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/Unknown command:/)
    end

    it "handles moving objects to HERE" do
      expect(interface).to receive(:get_input).and_return("o0=here", "c")
      engine.state.location = 5
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.object_at(0)).to eq(5)
    end

    it "handles moving objects to PAWS HERE location 255" do
      expect(interface).to receive(:get_input).and_return("o0=255", "c")
      engine.state.location = 7
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.state.object_at(0)).to eq(7)
    end

    it "handles different object location types for single object dump" do
      # WORN location
      engine.state.set_object_location(0, 253)
      expect(interface).to receive(:get_input).and_return("o0", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/O0: OBJECT \[At: Worn\]/)

      # General numeric location
      engine.state.set_object_location(0, 3)
      expect(interface).to receive(:get_input).and_return("o0", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/O0: OBJECT \[At: Location 3\]/)
    end

    it "handles detailed process inspection commands with args" do
      expect(interface).to receive(:get_input).and_return("p p0b1", "p invalid_spec", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/PROCESS 000/)
      expect(interface).to have_received(:output_text).with(/Invalid specification:/)
    end

    it "handles adding breakpoints interactively" do
      expect(interface).to receive(:get_input).and_return("b p0b1", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(engine.breakpoint_manager.breakpoints[:execution]).not_to be_empty
    end

    it "handles invalid delete breakpoint argument" do
      expect(interface).to receive(:get_input).and_return("b del", "b del 999", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/Usage: b del <n>/)
      expect(interface).to have_received(:output_text).with(/Invalid breakpoint index: 999/)
    end

    it "handles stack dump with active stack frames" do
      # Push some frames into process runner stacks
      engine.runner.process_stack << 1
      engine.runner.entry_index_stack << 2
      engine.runner.condact_index_stack << 3

      expect(interface).to receive(:get_input).and_return("t", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/▶ 0: P01 B2 C03/)
    end

    it "prints None when connections table is empty" do
      engine.state.connections.clear
      expect(interface).to receive(:get_input).and_return("con", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/None\./)
    end

    it "covers extra edge cases in move_object, dump_current_process, dump_breakpoints, dump_objects, and dump_vocabulary" do
      # 1. move_object to WORN (253) and CARRIED (254)
      expect(interface).to receive(:get_input).and_return("o0=253", "o0=254", "o0=252", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/moved to WORN/)
      expect(interface).to have_received(:output_text).with(/moved to CARRIED/)
      expect(interface).to have_received(:output_text).with(/moved to NOT_CREATED/)

      # 2. dump_current_process with non-array Hash-based processes, nonexistent process, empty entries, block not found
      # Change processes to Hash to trigger the other branch of dump_current_process
      engine.game_data["processes"] = {
        "0" => { "id" => 0, "entries" => [{}] },
        "1" => { "id" => 1, "entries" => [] },
      }
      expect(interface).to receive(:get_input).and_return("p p1", "p p999", "p p0b5", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/has no entries/).at_least(:once)
      expect(interface).to have_received(:output_text).with(/Process 999 not found/).at_least(:once)
      expect(interface).to have_received(:output_text).with(/Block 5 not found/).at_least(:once)

      # 3. dump_breakpoints with active breakpoints
      engine.breakpoint_manager.parse_line("L10")
      expect(interface).to receive(:get_input).and_return("b", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/LOCATIONS/)

      # 4. dump_objects with CARRIED (255) and NOT_CREATED (252)
      engine.state.set_object_location(0, 254)
      expect(interface).to receive(:get_input).and_return("o0", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/Carried/)

      engine.state.set_object_location(0, 252)
      expect(interface).to receive(:get_input).and_return("o0", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/Not created/)

      # 5. dump_vocabulary with nonexistent word ID
      expect(interface).to receive(:get_input).and_return("v999", "c")
      debugger.breakpoint_reached(0, 1, 0)
      expect(interface).to have_received(:output_text).with(/ID 999 not found/)
    end

    describe "Time-Travel Debugging" do
      let(:debug_engine) { PAWS::Engine.new(game_data, interface, debug_mode: true) }
      let(:debug_debugger) { PAWS::Debugger.new(debug_engine) }

      it "handles empty state history and lists recorded snapshots" do
        expect(interface).to receive(:get_input).and_return("hist", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/No snapshots recorded yet/)

        # Capture a couple of snapshots manually
        debug_engine.capture_state_snapshot("north")
        debug_engine.state.turns = 1
        debug_engine.capture_state_snapshot("south")

        expect(interface).to receive(:get_input).and_return("hist", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/Turn 0 @.*north/)
        expect(interface).to have_received(:output_text).with(/Turn 1 @.*south/)
      end

      it "shows detail view of a snapshot at an index" do
        debug_engine.capture_state_snapshot("north")

        expect(interface).to receive(:get_input).and_return("hist 0", "hist 99", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/Index:\s+0/)
        expect(interface).to have_received(:output_text).with(/Input:\s+north/)
        expect(interface).to have_received(:output_text).with(/Flags:\s+/)
        expect(interface).to have_received(:output_text).with(/No snapshot found at index 99/)
      end

      it "handles undo when history is too short" do
        debug_engine.capture_state_snapshot("north")
        expect(interface).to receive(:get_input).and_return("undo", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/Not enough history to undo/)
      end

      it "rewinds successfully using undo and prunes newer snapshots" do
        debug_engine.capture_state_snapshot("north")
        debug_engine.state.turns = 1
        debug_engine.state.set_flag(8, 42)
        debug_engine.capture_state_snapshot("south")

        expect(debug_engine.state_history.size).to eq(2)

        expect(interface).to receive(:get_input).and_return("undo", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/⏪ Rewound to Snapshot \[0\].*Turn 0/)
        expect(debug_engine.state.get_flag(8)).to eq(0) # restored from turn 0 state where flag 8 was 0

        # Newer snapshots must be pruned (only index 0 remains)
        expect(debug_engine.state_history.size).to eq(1)
        expect(debug_engine.state_history[0].turn).to eq(0)
      end

      it "rewinds to a specific snapshot index" do
        debug_engine.capture_state_snapshot("north")
        debug_engine.state.turns = 1
        debug_engine.state.set_flag(8, 42)
        debug_engine.capture_state_snapshot("south")

        expect(interface).to receive(:get_input).and_return("rewind", "rewind 99", "rewind 0", "c")
        debug_debugger.breakpoint_reached(0, 1, 0)
        expect(interface).to have_received(:output_text).with(/Usage: rewind <index>/)
        expect(interface).to have_received(:output_text).with(/No snapshot found at index 99/)
        expect(interface).to have_received(:output_text).with(/⏪ Rewound to Snapshot \[0\].*Turn 0/)

        # Verifies history is pruned after index 0
        expect(debug_engine.state_history.size).to eq(1)
      end
    end
  end
end
