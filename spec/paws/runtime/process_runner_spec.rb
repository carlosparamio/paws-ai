# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/game_state"
require "paws/runtime/engine"
require "paws/runtime/process_runner"

RSpec.describe PAWS::ProcessRunner do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Loc 0" }, { "description" => "Loc 1" }],
      "messages" => ["Msg 0", "Msg 1", "Msg 2", "Msg 3", "Msg 4"],
      "system_messages" => Array.new(60) { |i| "SysMsg #{i}" },
      "objects" => [
        { "description" => +"obj 0", "initially_at" => 1, "weight" => 2, "noun_id" => 10, "attrs_lo" => 0 },
        { "description" => +"obj 1", "initially_at" => 254, "weight" => 1, "noun_id" => 11, "attrs_lo" => 32768 }, # Attr 15: Wearable
        { "description" => +"obj 2", "initially_at" => 253, "weight" => 1, "noun_id" => 12, "attrs_lo" => 32768 },
      ],
      "connections" => [[0, [[1, 1]]]],
      "vocabulary" => [],
      "processes" => [
        { "id" => 0, "entries" => [] },
        { "id" => 1, "entries" => [] },
        { "id" => 2, "entries" => [] },
        { "id" => 3, "entries" => [
          { "verb" => 255, "noun" => 255, "condacts" => [
            { "name" => "MESSAGE", "params" => [2] },
          ] },
        ] },
        { "id" => 4, "entries" => [
          { "verb" => 10, "noun" => 10, "condacts" => [
            { "name" => "MESSAGE", "params" => [0] },
            { "name" => "DONE", "params" => [] },
          ] },
          { "verb" => 20, "noun" => 20, "condacts" => [
            { "name" => "MESSAGE", "params" => [1] },
          ] },
        ] },
        { "id" => 5, "entries" => [
          { "verb" => 10, "noun" => 10, "condacts" => [
            { "name" => "MESSAGE", "params" => [3] },
            { "name" => "DONE", "params" => [] },
          ] },
          { "verb" => 20, "noun" => 20, "condacts" => [
            { "name" => "MESSAGE", "params" => [4] },
          ] },
        ] },
      ],
      "defaults" => { "max_carried" => 4 },
    }
  end

  let(:engine) { PAWS::Engine.new(game_data, interface) }
  subject(:runner) { PAWS::ProcessRunner.new(engine) }

  before do
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:get_input).and_return("")
    allow(interface).to receive(:clear_screen)
    allow(interface).to receive(:wait_for_key)
    allow(interface).to receive(:set_colors)
    allow(interface).to receive(:colorize) { |val, *args| val.to_s }
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    # Most runner tests need the engine to be in 'running' state
    engine.instance_variable_set(:@running, true)
    engine.describe_flag = false
    runner.instance_variable_get(:@execution_context).push_frame
  end

  describe "conditions" do
    describe "AT/NOTAT/ATGT/ATLT" do
      before { engine.state.location = 5 }

      it "AT succeeds when at location" do
        expect(runner.send(:condact_at, 5)).to eq(:ok)
        result = runner.send(:condact_at, 3)
        expect(result).to be_failed
      end

      it "NOTAT succeeds when not at location" do
        expect(runner.send(:condact_notat, 3)).to eq(:ok)
        result = runner.send(:condact_notat, 5)
        expect(result).to be_failed
      end

      it "ATGT succeeds when location > param" do
        expect(runner.send(:condact_atgt, 3)).to eq(:ok)
        result = runner.send(:condact_atgt, 5)
        expect(result).to be_failed
      end

      it "ATLT succeeds when location < param" do
        expect(runner.send(:condact_atlt, 10)).to eq(:ok)
        result = runner.send(:condact_atlt, 5)
        expect(result).to be_failed
      end
    end

    describe "PRESENT/ABSENT" do
      before { engine.state.location = 1 }

      it "PRESENT succeeds for objects here, carried, or worn" do
        expect(runner.send(:condact_present, 0)).to eq(:ok)  # at loc 1
        expect(runner.send(:condact_present, 1)).to eq(:ok)  # carried
        expect(runner.send(:condact_present, 2)).to eq(:ok)  # worn
      end

      it "ABSENT succeeds for objects not present" do
        engine.state.location = 0
        expect(runner.send(:condact_absent, 0)).to eq(:ok)
      end
    end

    describe "CARRIED/NOTCARR/WORN/NOTWORN" do
      it "CARRIED succeeds for carried objects" do
        expect(runner.send(:condact_carried, 1)).to eq(:ok)
        result = runner.send(:condact_carried, 0)
        expect(result).to be_failed
      end

      it "WORN succeeds for worn objects" do
        expect(runner.send(:condact_worn, 2)).to eq(:ok)
        result = runner.send(:condact_worn, 0)
        expect(result).to be_failed
      end
    end

    describe "flag conditions" do
      before { engine.state.set_flag(50, 10) }

      it "ZERO/NOTZERO" do
        expect(runner.send(:condact_zero, 50)).to eq(:failed)
        expect(runner.send(:condact_zero, 51)).to eq(:ok)
        expect(runner.send(:condact_notzero, 50)).to eq(:ok)
      end

      it "EQ/NOTEQ" do
        expect(runner.send(:condact_eq, 50, 10)).to eq(:ok)
        expect(runner.send(:condact_eq, 50, 5)).to eq(:failed)
        expect(runner.send(:condact_noteq, 50, 5)).to eq(:ok)
      end

      it "GT/LT" do
        expect(runner.send(:condact_gt, 50, 5)).to eq(:ok)
        expect(runner.send(:condact_gt, 50, 10)).to eq(:failed)
        expect(runner.send(:condact_lt, 50, 15)).to eq(:ok)
      end

      it "SAME/NOTSAME" do
        engine.state.set_flag(51, 10)
        expect(runner.send(:condact_same, 50, 51)).to eq(:ok)
        engine.state.set_flag(51, 5)
        expect(runner.send(:condact_notsame, 50, 51)).to eq(:ok)
      end

      it "BIGGER/SMALLER" do
        engine.state.set_flag(50, 20)
        engine.state.set_flag(51, 10)
        expect(runner.send(:condact_bigger, 50, 51)).to eq(:ok)
        expect(runner.send(:condact_bigger, 51, 50)).to eq(:failed)
        expect(runner.send(:condact_smaller, 51, 50)).to eq(:ok)
        expect(runner.send(:condact_smaller, 50, 51)).to eq(:failed)
      end
    end

    describe "ISAT/ISNOTAT" do
      it "checks object location" do
        expect(runner.send(:condact_isat, 0, 1)).to eq(:ok)
        expect(runner.send(:condact_isat, 1, 254)).to eq(:ok)
        expect(runner.send(:condact_isnotat, 0, 5)).to eq(:ok)
      end
    end

    describe "CHANCE" do
      it "succeeds based on probability" do
        allow(runner).to receive(:rand).with(1..100).and_return(50)
        expect(runner.send(:condact_chance, 50)).to eq(:ok)

        allow(runner).to receive(:rand).with(1..100).and_return(51)
        result = runner.send(:condact_chance, 50)
        expect(result).to be_failed
      end
    end
  end

  describe "actions" do
    describe "DONE/NOTDONE/OK" do
      let(:push_frame) {
        -> {
          runner.instance_variable_get(:@done_stack).push(false)
          runner.instance_variable_get(:@process_stack).push(0)
          runner.instance_variable_get(:@mode_stack).push(:response)
        }
      }

      it "DONE sets done_flag" do
        push_frame.call
        runner.send(:condact_done)
        expect(runner.instance_variable_get(:@done_stack).last).to be true
      end

      it "NOTDONE clears done_flag" do
        push_frame.call
        runner.instance_variable_get(:@done_stack)[-1] = true # simulate DONE was set
        runner.send(:condact_notdone)
        expect(runner.instance_variable_get(:@done_stack).last).to be false
      end

      it "OK outputs message and sets done" do
        push_frame.call
        expect(interface).to receive(:output_text).with("SysMsg 15", hash_including({}))
        runner.send(:condact_ok)
        expect(runner.instance_variable_get(:@done_stack).last).to be true
        expect(engine.done_flag).to be true
      end
    end

    describe "GOTO/DESC" do
      it "GOTO changes location" do
        runner.send(:condact_goto, 10)
        expect(engine.state.location).to eq(10)
      end

      it "DESC requests description" do
        engine.instance_variable_set(:@describe_flag, false)
        catch(:desc_jump) { runner.send(:condact_desc) }
        expect(engine.describe_flag).to be true
      end
    end

    describe "MESSAGE/SYSMESS" do
      it "MESSAGE outputs message" do
        expect(interface).to receive(:output_text).with("Msg 1", hash_including({}))
        runner.send(:condact_message, 1)
      end

      it "SYSMESS outputs system message" do
        expect(interface).to receive(:output_text).with("SysMsg 5", hash_including(newline: false))
        runner.send(:condact_sysmess, 5)
      end
    end

    describe "object manipulation" do
      describe "GET" do
        before {
          engine.state.location = 1
          runner.instance_variable_get(:@done_stack).push(false)
        }

        it "picks up object at location and emits SM36" do
          expect(interface).to receive(:output_text).with("SysMsg 36", hash_including({}))
          runner.send(:condact_get, 0)
          expect(engine.state.object_carried?(0)).to be true
        end

        it "fails if already carried (SM25)" do
          expect(interface).to receive(:output_text).with("SysMsg 25", hash_including({}))
          runner.send(:condact_get, 1)
        end

        it "fails if not here (SM26) and sets DONE" do
          engine.state.location = 0
          expect(interface).to receive(:output_text).with("SysMsg 26", hash_including({}))
          runner.send(:condact_get, 0)
          expect(engine.done_flag).to be true
        end

        it "fails if inventory is full (SM27)" do
          engine.state.set_flag(PAWS::GameState::FLAG_MAX_CARRIED, 1) # Already has obj 1
          expect(interface).to receive(:output_text).with("SysMsg 27", hash_including({}))
          runner.send(:condact_get, 0)
          expect(engine.done_flag).to be true
        end

        it "fails if weight limit is reached (SM43)" do
          engine.state.set_flag(PAWS::GameState::FLAG_MAX_WEIGHT, 2)
          expect(interface).to receive(:output_text).with("SysMsg 43", hash_including({}))
          runner.send(:condact_get, 0)
        end

        it "handles objno 255 by showing SM26" do
          expect(interface).to receive(:output_text).with("SysMsg 26", hash_including({}))
          runner.send(:condact_get, 255)
        end
      end

      describe "DROP" do
        before { runner.instance_variable_get(:@done_stack).push(false) }

        it "drops carried object and emits SM39" do
          engine.state.location = 5
          expect(interface).to receive(:output_text).with("SysMsg 39", hash_including({}))
          runner.send(:condact_drop, 1)
          expect(engine.state.object_at(1)).to eq(5)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end

        it "fails if not carried" do
          expect(interface).to receive(:output_text).with("SysMsg 28", hash_including({}))
          runner.send(:condact_drop, 0)
        end

        it "handles objno 255 by showing SM28" do
          expect(interface).to receive(:output_text).with("SysMsg 28", hash_including({}))
          runner.send(:condact_drop, 255)
        end

        it "fails if trying to drop a worn object (SM24)" do
          expect(interface).to receive(:output_text).with("SysMsg 24", hash_including({}))
          runner.send(:condact_drop, 2) # obj 2 is initially worn
        end

        it "fails if trying to drop an object that is at the location but not carried (SM49)" do
          engine.state.location = 1 # obj 0 is initially at location 1
          expect(interface).to receive(:output_text).with("SysMsg 49", hash_including({}))
          runner.send(:condact_drop, 0)
        end
      end

      describe "WEAR/REMOVE" do
        before { runner.instance_variable_get(:@done_stack).push(false) }

        it "WEAR moves carried to worn, emits SM37 and decrements Flag 1" do
          expect(interface).to receive(:output_text).with("SysMsg 37", hash_including({}))
          runner.send(:condact_wear, 1)
          expect(engine.state.object_worn?(1)).to be true
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end

        it "WEAR fails if trying to wear an already worn object (SM29)" do
          expect(interface).to receive(:output_text).with("SysMsg 29", hash_including({}))
          runner.send(:condact_wear, 2) # obj 2 is initially worn
        end

        it "WEAR fails if trying to wear an object that is here but not carried (SM49)" do
          engine.state.location = 1 # obj 0 is initially at location 1
          expect(interface).to receive(:output_text).with("SysMsg 49", hash_including({}))
          runner.send(:condact_wear, 0)
        end

        it "WEAR fails if trying to wear an object that is not present at all (SM28)" do
          engine.state.location = 0 # obj 0 is at location 1, so not here
          expect(interface).to receive(:output_text).with("SysMsg 28", hash_including({}))
          runner.send(:condact_wear, 0)
        end

        it "WEAR fails if trying to wear a non-wearable object (SM40)" do
          # make obj 0 carried
          engine.state.set_object_location(0, 254)
          expect(interface).to receive(:output_text).with("SysMsg 40", hash_including({}))
          runner.send(:condact_wear, 0)
        end

        it "REMOVE moves worn to carried, emits SM38 and increments Flag 1" do
          expect(interface).to receive(:output_text).with("SysMsg 38", hash_including({}))
          runner.send(:condact_remove, 2)
          expect(engine.state.object_carried?(2)).to be true
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(2)
        end

        it "REMOVE fails if inventory is full (SM42)" do
          engine.state.set_flag(PAWS::GameState::FLAG_MAX_CARRIED, 1) # Already has obj 1
          expect(interface).to receive(:output_text).with("SysMsg 42", hash_including({}))
          runner.send(:condact_remove, 2)
        end

        it "REMOVE fails if trying to remove an unworn but carried object (SM50)" do
          expect(interface).to receive(:output_text).with("SysMsg 50", hash_including({}))
          runner.send(:condact_remove, 1) # obj 1 is carried, not worn
        end

        it "REMOVE fails if trying to remove an unworn and not carried object (SM23)" do
          expect(interface).to receive(:output_text).with("SysMsg 23", hash_including({}))
          runner.send(:condact_remove, 0) # obj 0 is not worn or carried
        end

        it "REMOVE fails if trying to remove a non-removable object (SM41)" do
          engine.state.set_object_attr(2, 15, false) # make obj 2 non-wearable/removable
          expect(interface).to receive(:output_text).with("SysMsg 41", hash_including({}))
          runner.send(:condact_remove, 2)
        end

        it "WEAR with 255 aborts with SM28" do
          expect(interface).to receive(:output_text).with("SysMsg 28", hash_including({}))
          expect(runner.send(:condact_wear, 255)).to eq(:failed)
        end

        it "REMOVE with 255 aborts with SM23" do
          expect(interface).to receive(:output_text).with("SysMsg 23", hash_including({}))
          expect(runner.send(:condact_remove, 255)).to eq(:failed)
        end
      end

      describe "CREATE/DESTROY" do
        it "CREATE places object at current location and decrements Flag 1 if it was carried" do
          engine.state.location = 5
          runner.send(:condact_create, 1) # obj 1 is carried
          expect(engine.state.object_at(1)).to eq(5)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end

        it "DESTROY moves object to not_created and decrements Flag 1 if it was carried" do
          runner.send(:condact_destroy, 1)
          expect(engine.state.object_at(1)).to eq(252)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end
      end

      describe "SWAP/PLACE" do
        it "SWAP exchanges object locations and updates referred object" do
          runner.send(:condact_swap, 0, 1)
          expect(engine.state.object_at(0)).to eq(254)
          expect(engine.state.object_at(1)).to eq(1)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(1)
        end

        it "PLACE sets object location and updates Flag 1 if destination is 254" do
          runner.send(:condact_place, 0, 254)
          expect(engine.state.object_at(0)).to eq(254)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(2)
        end
      end

      describe "DROPALL" do
        it "drops all carried objects and resets Flag 1" do
          engine.state.location = 5
          runner.send(:condact_dropall)
          expect(engine.state.object_at(1)).to eq(5)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end
      end

      describe "PUTIN/TAKEOUT" do
        it "PUTIN moves carried to container and emits SM44" do
          expect(interface).to receive(:output_text).with("SysMsg 44", hash_including({}))
          runner.send(:condact_putin, 1, 100)
          expect(engine.state.object_at(1)).to eq(100)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(0)
        end

        it "TAKEOUT moves from container to carried and emits SM36" do
          engine.state.set_object_location(0, 100)
          expect(interface).to receive(:output_text).with("SysMsg 36", hash_including({}))
          runner.send(:condact_takeout, 0, 100)
          expect(engine.state.object_at(0)).to eq(254)
          expect(engine.state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(2)
        end

        it "PUTIN with 255 aborts with SM28" do
          expect(runner.send(:condact_putin, 255, 100)).to eq(:failed)
        end

        it "PUTIN with worn object aborts with SM24" do
          expect(interface).to receive(:output_text).with("SysMsg 24", hash_including({}))
          runner.send(:condact_putin, 2, 100) # obj 2 is worn
        end

        it "PUTIN with object at location but not carried aborts with SM49" do
          engine.state.location = 1 # obj 0 is at location 1
          expect(interface).to receive(:output_text).with("SysMsg 49", hash_including({}))
          runner.send(:condact_putin, 0, 100)
        end

        it "PUTIN with object not carried aborts with SM28" do
          engine.state.location = 5 # obj 0 is at location 1, not here
          expect(interface).to receive(:output_text).with("SysMsg 28", hash_including({}))
          runner.send(:condact_putin, 0, 100)
        end

        it "TAKEOUT with 255 aborts with SM26" do
          expect(runner.send(:condact_takeout, 255, 100)).to eq(:failed)
        end

        it "TAKEOUT with worn/carried aborts with SM25" do
          expect(interface).to receive(:output_text).with("SysMsg 25", hash_including({}))
          runner.send(:condact_takeout, 1, 100) # obj 1 is carried
        end

        it "TAKEOUT with object here aborts with SM45" do
          engine.state.location = 1 # obj 0 is here
          expect(interface).to receive(:output_text).with("SysMsg 45", hash_including({}))
          runner.send(:condact_takeout, 0, 1)
        end

        it "TAKEOUT with object not in container aborts with SM52" do
          engine.state.set_object_location(0, 99) # not 100
          expect(interface).to receive(:output_text).with("SysMsg 52", hash_including({}))
          runner.send(:condact_takeout, 0, 100)
        end

        it "TAKEOUT with weight limits exceeded aborts with SM43" do
          engine.state.set_object_location(0, 100)
          engine.state.set_flag(PAWS::GameState::FLAG_MAX_WEIGHT, 1) # small weight
          expect(interface).to receive(:output_text).with("SysMsg 43", hash_including({}))
          runner.send(:condact_takeout, 0, 100)
        end

        it "TAKEOUT with max carried exceeded aborts with SM27" do
          engine.state.set_object_location(0, 100)
          engine.state.set_flag(PAWS::GameState::FLAG_MAX_CARRIED, 1) # already has obj 1
          expect(interface).to receive(:output_text).with("SysMsg 27", hash_including({}))
          runner.send(:condact_takeout, 0, 100)
        end
      end
    end

    describe "automatic wrappers (AUTO*)" do
      before do
        engine.state.location = 1
        # Configure WHATO so it finds object 0 (noun 10).
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
        engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
        runner.instance_variable_get(:@done_stack).push(false)
      end

      it "AUTOG calls WHATO and then GET" do
        expect(interface).to receive(:output_text).with("SysMsg 36", hash_including({}))
        runner.send(:condact_autog)
        expect(engine.state.object_carried?(0)).to be true
      end

      it "AUTOG fails if object not found (SM26)" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 99) # No match
        expect(interface).to receive(:output_text).with("SysMsg 26", hash_including({}))
        runner.send(:condact_autog)
      end
    end

    describe "flag manipulation" do
      it "SET/CLEAR/LET" do
        runner.send(:condact_set, 50)
        expect(engine.state.get_flag(50)).to eq(255)
        runner.send(:condact_clear, 50)
        expect(engine.state.get_flag(50)).to eq(0)
        runner.send(:condact_let, 50, 42)
        expect(engine.state.get_flag(50)).to eq(42)
      end

      it "PLUS/MINUS" do
        engine.state.set_flag(50, 10)
        runner.send(:condact_plus, 50, 5)
        expect(engine.state.get_flag(50)).to eq(15)
        runner.send(:condact_minus, 50, 20)
        expect(engine.state.get_flag(50)).to eq(0)
      end

      it "dispatches migrated flag condacts through execute_condact" do
        expect(runner.send(:execute_condact, { "name" => "SET", "params" => [50] })).to eq(:ok)
        expect(engine.state.get_flag(50)).to eq(255)

        expect(runner.send(:execute_condact, { "name" => "COPYFF", "params" => [50, 51] })).to eq(:ok)
        expect(engine.state.get_flag(51)).to eq(255)
      end

      it "dispatches migrated flag condacts from the engine-owned runner" do
        expect(engine.runner.send(:execute_condact, { "name" => "SET", "params" => [50] })).to eq(:ok)
        expect(engine.state.get_flag(50)).to eq(255)
      end
    end

    describe "information condacts" do
      it "MESSAGE adds newline, MES does not" do
        expect(interface).to receive(:output_text).with("Msg 0", hash_including(newline: true))
        runner.send(:condact_message, 0)
        expect(interface).to receive(:output_text).with("Msg 1", hash_including(newline: false))
        runner.send(:condact_mes, 1)
      end

      it "TURNS uses SM17-20 for pluralization" do
        engine.state.set_flag(PAWS::GameState::FLAG_TURNS_LO, 1)
        expect(interface).to receive(:output_text).with("SysMsg 17", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("1", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 18", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 20", hash_including(newline: true))
        runner.send(:condact_turns)

        engine.state.set_flag(PAWS::GameState::FLAG_TURNS_LO, 2)
        expect(interface).to receive(:output_text).with("SysMsg 17", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("2", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 18", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 19", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 20", hash_including(newline: true))
        runner.send(:condact_turns)
      end

      it "TURNS does not emit a blank line when SM20 is empty" do
        engine.game_data["system_messages"][20] = ""
        engine.state.set_flag(PAWS::GameState::FLAG_TURNS_LO, 2)

        expect(engine).to receive(:output_sysmess).with(17, newline: false).ordered
        expect(engine).to receive(:output_text).with("2", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(18, newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(19, newline: false).ordered
        expect(engine).not_to receive(:output_sysmess).with(20, any_args)

        runner.send(:condact_turns)
      end

      it "INVEN lists carried and worn objects (with SM10)" do
        # obj 1 is at 254 (carried), obj 2 is at 253 (worn)
        # Vertical list by default (Flag 53 bit 6 = 0)
        expect(interface).to receive(:output_text).with("SysMsg 9", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("  obj 1", hash_including(newline: true))
        expect(interface).to receive(:output_text).with("  obj 2", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 10", hash_including(newline: true))

        runner.send(:condact_inven)
      end

      it "INVEN lists carried and worn objects as a continuous list (Flag 53 bit 6 = 1)" do
        engine.state.set_flag(PAWS::GameState::FLAG_LISTING_CONTROL, 64) # continuous list
        expect(interface).to receive(:output_text).with("SysMsg 9", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("obj 1", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 47", hash_including(newline: false)) # " y "
        expect(interface).to receive(:output_text).with("obj 2", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 10", hash_including(newline: false)) # " (llevado puesto)"

        runner.send(:condact_inven)
      end

      it "INVEN outputs empty state if no objects are carried or worn" do
        engine.state.set_object_location(1, 0) # move away from carried
        engine.state.set_object_location(2, 0) # move away from worn
        expect(interface).to receive(:output_text).with("SysMsg 9", hash_including(newline: false))
        expect(interface).to receive(:output_text).with("SysMsg 11", hash_including(newline: true)) # "nada"
        runner.send(:condact_inven)
      end
    end

    describe "persistence and end" do
      it "END prompts for replay and restarts if accepted" do
        expect(interface).to receive(:output_text).with("SysMsg 13", any_args).ordered
        expect(interface).to receive(:wait_for_key).and_return("s")
        expect(engine).to receive(:restart).ordered
        runner.send(:condact_end)
      end

      it "END prompts for replay and stops if rejected" do
        expect(interface).to receive(:output_text).with("SysMsg 13", any_args).ordered
        expect(interface).to receive(:wait_for_key).and_return("n")
        expect(engine).to receive(:stop).ordered
        runner.send(:condact_end)
      end

      it "QUIT prompts for confirmation and returns :ok if accepted (after stopping engine)" do
        expect(interface).to receive(:output_text).with("SysMsg 12", any_args).ordered
        expect(interface).to receive(:wait_for_key).and_return("s")
        expect(engine).to receive(:stop).ordered
        expect(runner.send(:condact_quit)).to eq(:ok)
      end

      it "QUIT prompts for confirmation and returns :failed (with done_flag true) if rejected" do
        expect(interface).to receive(:output_text).with("SysMsg 12", any_args).ordered
        expect(interface).to receive(:wait_for_key).and_return("n")
        expect(engine).not_to receive(:stop)
        expect(runner.send(:condact_quit)).to eq(:failed)
        expect(runner.instance_variable_get(:@done_stack).last).to be true
      end

      it "aborts execution of subsequent condacts if engine stops" do
        runner.instance_variable_get(:@condact_index_stack).push(0)
        condacts = [
          { "name" => "END", "params" => [] },
          { "name" => "MES", "params" => ["Should not see this"] },
        ]

        # Mock END to stop engine
        expect(interface).to receive(:output_text).with("SysMsg 13", any_args)
        expect(interface).to receive(:wait_for_key).and_return("n")
        expect(engine).to receive(:stop).and_call_original

        # Should NOT receive MES output
        expect(interface).not_to receive(:output_text).with("Should not see this", any_args)

        runner.send(:run_condacts, condacts)
      end
    end

    describe "copy operations" do
      it "COPYOF/COPYOO/COPYFO/COPYFF" do
        runner.send(:condact_copyof, 0, 50)
        expect(engine.state.get_flag(50)).to eq(1)
        runner.send(:condact_copyoo, 1, 0)
        engine.state.set_flag(60, 10)
        runner.send(:condact_copyfo, 60, 0)
        expect(engine.state.object_at(0)).to eq(10)
        runner.send(:condact_copyff, 60, 52)
        expect(engine.state.get_flag(52)).to eq(10)
      end
    end

    describe "RAMSAVE/RAMLOAD" do
      it "saves and restores state up to flag limit" do
        engine.state.location = 10
        engine.state.set_flag(30, 100)
        engine.state.set_flag(255, 200)
        runner.send(:condact_ramsave)

        engine.state.location = 0
        engine.state.set_flag(30, 0)
        engine.state.set_flag(255, 0)

        # RAMLOAD 254 should NOT reload flag 255
        runner.send(:condact_ramload, 254)

        expect(engine.state.location).to eq(10) # Flag 38
        expect(engine.state.get_flag(30)).to eq(100)
        expect(engine.state.get_flag(255)).to eq(0) # Preserved
      end
    end

    describe "DOALL" do
      before {
        runner.instance_variable_get(:@condact_index_stack).push(0)
        runner.instance_variable_get(:@done_stack).push(false)
      }

      it "aborts loop if inventory becomes full" do
        engine.state.location = 1
        engine.state.set_flag(PAWS::GameState::FLAG_MAX_CARRIED, 1) # Already has obj 1
        condacts = [{ "name" => "GET", "params" => [0] }]
        expect(interface).to receive(:output_text).with("SysMsg 27", hash_including({}))
        runner.send(:condact_doall, 1, condacts)
        expect(engine.state.object_carried?(0)).to be false
      end

      it "runs condacts for all objects at a location" do
        process = {
          "entries" => [
            { "verb" => 0, "noun" => 0, "condacts" => [{ "name" => "DOALL", "params" => [0] }] },
          ],
        }
        engine.game_data["processes"] = { "10" => process }
        engine.state.location = 0

        runner.send(:run_process, 10)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).not_to eq(255)
      end

      it "skips execution if object matches Noun 2 (EXCEPT)" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN2, 5) # EXCEPT object with noun_id 5

        # Assuming object 0 has noun_id 5. Set it in game_data
        engine.game_data["objects"][0] = { "noun_id" => 5, "initial_location" => 0, "name" => "apple" }
        engine.game_data["objects"][1] = { "noun_id" => 6, "initial_location" => 0, "name" => "banana" }
        engine.state.reset!
        engine.state.location = 0
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN2, 5) # EXCEPT object with noun_id 5

        process = {
          "entries" => [
            { "verb" => 0, "noun" => 0, "condacts" => [{ "name" => "DOALL", "params" => [0] }] },
          ],
        }
        engine.game_data["processes"] = { "10" => process }
        runner.send(:run_process, 10)

        # Only object 1 should have been processed, so REFERRED_OBJECT is 1
        expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(1)
      end
    end

    describe "SAVE/LOAD" do
      it "SAVE calls interface save_game" do
        expect(interface).to receive(:save_game).with(engine.state)
        runner.send(:condact_save)
      end

      it "LOAD calls interface load_game and returns ok on success" do
        expect(interface).to receive(:load_game).with(engine).and_return(true)
        expect(runner.send(:condact_load)).to eq(:ok)
      end

      it "LOAD handles failure with SM54 and ANYKEY" do
        expect(interface).to receive(:load_game).with(engine).and_return(false)
        expect(interface).to receive(:output_text).with("SysMsg 54", any_args)
        expect(interface).to receive(:output_text).with("SysMsg 16", any_args)
        expect(interface).to receive(:wait_for_key)
        expect(interface).to receive(:flush_input_buffer)

        catch(:desc_jump) { runner.send(:condact_load) }
        expect(engine.describe_flag).to be true
      end
    end

    describe "SAVE/LOAD" do
      it "SAVE calls interface save_game" do
        expect(engine.interface).to receive(:save_game).with(engine.state)
        expect(runner.send(:execute_condact, { "name" => "SAVE", "params" => [] })).to eq(:ok)
      end

      it "LOAD calls interface load_game and returns ok on success" do
        expect(engine.interface).to receive(:load_game).with(engine).and_return(true)
        expect(runner.send(:execute_condact, { "name" => "LOAD", "params" => [] })).to eq(:ok)
      end

      it "LOAD handles failure with SM54 and ANYKEY" do
        expect(engine.interface).to receive(:load_game).with(engine).and_return(false)
        expect(engine).to receive(:output_sysmess).with(54, newline: true).ordered
        expect(engine).to receive(:output_sysmess).with(16, newline: false).ordered
        expect(engine.interface).to receive(:wait_for_key).ordered
        expect(engine.interface).to receive(:flush_input_buffer).ordered

        catch(:desc_jump) do
          runner.send(:execute_condact, { "name" => "LOAD", "params" => [] })
        end
      end
    end

    describe "RAMSAVE/RAMLOAD" do
      it "saves and restores state up to flag limit" do
        runner.send(:execute_condact, { "name" => "LET", "params" => [50, 100] })
        runner.send(:execute_condact, { "name" => "RAMSAVE", "params" => [] })

        runner.send(:execute_condact, { "name" => "LET", "params" => [50, 200] })
        expect(engine.state.get_flag(50)).to eq(200)

        expect(runner.send(:execute_condact, { "name" => "RAMLOAD", "params" => [60] })).to eq(:ok)
        expect(engine.state.get_flag(50)).to eq(100) # restored
      end

      it "fails RAMLOAD if not successful" do
        expect(engine.state).to receive(:ramload).with(256).and_return(false)
        expect(runner.send(:execute_condact, { "name" => "RAMLOAD", "params" => [256] })).to eq(:failed)
      end
    end

    describe "Condition condacts (PREP, NOUN2, ADJECT2)" do
      it "PREP succeeds if prep matches" do
        engine.state.set_flag(PAWS::GameState::FLAG_PREP, 5)
        expect(runner.send(:condact_prep, 5)).to eq(:ok)
        expect(runner.send(:condact_prep, 4)).to eq(PAWS::ExecutionResult.failed("actual value is 5"))
      end

      it "NOUN2 succeeds if noun matches" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN2, 10)
        expect(runner.send(:condact_noun2, 10)).to eq(:ok)
        expect(runner.send(:condact_noun2, 4)).to eq(PAWS::ExecutionResult.failed("actual value is 10"))
      end

      it "ADJECT2 succeeds if adject matches" do
        engine.state.set_flag(PAWS::GameState::FLAG_ADJECT2, 15)
        expect(runner.send(:condact_adject2, 15)).to eq(:ok)
        expect(runner.send(:condact_adject2, 4)).to eq(PAWS::ExecutionResult.failed("actual value is 15"))
      end
    end

    describe "TIMEOUT / TIME" do
      it "TIME sets duration and flags" do
        runner.send(:condact_time, 10, 3)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH)).to eq(10)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(3)
      end

      it "TIMEOUT checks if timeout flag is set" do
        engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 0)
        expect(runner.send(:condact_timeout)).to eq(PAWS::ExecutionResult.failed("timeout flag is 0"))

        engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 128)
        expect(runner.send(:condact_timeout)).to eq(:ok)
      end
    end

    describe "WEIGHT / WEIGH / ABILITY" do
      it "ABILITY sets max carried and weight limits" do
        runner.send(:condact_ability, 5, 20)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_MAX_CARRIED)).to eq(5)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_MAX_WEIGHT)).to eq(20)
      end

      it "WEIGHT sets flag to total carried weight" do
        # We need a stub for total_carried_weight
        allow(engine.state).to receive(:total_carried_weight).and_return(42)
        runner.send(:condact_weight, 50)
        expect(engine.state.get_flag(50)).to eq(42)
      end

      it "WEIGH sets flag to specific object weight" do
        allow(engine.state).to receive(:object_weight).with(3).and_return(12)
        runner.send(:condact_weigh, 3, 60)
        expect(engine.state.get_flag(60)).to eq(12)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(3)
      end
    end

    describe "Interface Condacts (INK, PAPER, BEEP, PROMPT)" do
      it "INK sets ink color via interface" do
        expect(interface).to receive(:set_colors).with(ink: "red")
        runner.send(:condact_ink, 2)
      end

      it "PAPER sets paper color via interface" do
        expect(interface).to receive(:set_colors).with(paper: "blue")
        runner.send(:condact_paper, 1)
      end

      it "BEEP does not raise errors (no-op in CLI)" do
        expect(runner.send(:condact_beep, 10, 5)).to eq(:ok)
      end

      it "PROMPT sets prompt string flag" do
        runner.send(:condact_prompt, 10)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_PROMPT)).to eq(10)
      end
    end

    describe "Miscellaneous Condacts" do
      it "MODE sets screen mode flag" do
        runner.send(:condact_mode, 1, nil)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_SCREEN_MODE)).to eq(1)
      end

      it "reports unsupported platform-dependent display and external condacts" do
        expect(runner.send(:condact_line, 5)).to eq(:unsupported)
        expect(runner.send(:condact_printat, 5, 10)).to eq(:unsupported)
        expect(runner.send(:condact_extern, 1)).to eq(:unsupported)
        expect(runner.send(:condact_border, 1)).to eq(:unsupported)
        expect(runner.send(:condact_picture, 1)).to eq(:unsupported)
        expect(runner.send(:condact_graphic, 1)).to eq(:unsupported)

        expect(runner.unsupported_condacts.map { |entry| entry[:name] }).to include(
          "LINE", "PRINTAT", "EXTERN", "BORDER", "PICTURE", "GRAPHIC"
        )
        expect(runner.unsupported_condacts).to include(
          hash_including(name: "GRAPHIC", feature: :graphics_mode)
        )
      end

      it "does not print unsupported condact warnings in normal play mode" do
        expect { runner.send(:condact_printat, 5, 10) }.not_to output.to_stderr
      end

      it "prints unsupported condact warnings when verbosity is enabled" do
        allow(interface).to receive(:output_debug)
        verbose_engine = PAWS::Engine.new(game_data, interface, verbosity: 2)
        verbose_runner = PAWS::ProcessRunner.new(verbose_engine)

        expect { verbose_runner.send(:condact_printat, 5, 10) }
          .to output(/Unsupported condact: PRINTAT/).to_stderr
      end

      it "keeps truly optional effects as explicit no-ops" do
        expect(runner.send(:condact_protect)).to eq(:ok)
        expect(runner.send(:condact_beep, 10, 5)).to eq(:ok)
      end

      it "SAVEAT / BACKAT save and restore location" do
        engine.state.location = 10
        runner.send(:condact_saveat)
        engine.state.location = 20
        runner.send(:condact_backat)
        expect(engine.state.location).to eq(10)
      end

      it "INPUT reads a number from user and sets flag" do
        expect(interface).to receive(:get_input).and_return("42")
        runner.send(:condact_input, 15)
        expect(engine.state.get_flag(15)).to eq(42)
      end

      it "NEWTEXT clears phrases" do
        expect(engine).to receive(:clear_phrases)
        runner.send(:condact_newtext)
      end

      it "BELL rings the bell" do
        expect { runner.send(:condact_bell) }.to output("\a").to_stdout
      end

      it "RESET_FLAG sets flag to 0" do
        engine.state.set_flag(20, 99)
        runner.send(:condact_reset_flag, 20)
        expect(engine.state.get_flag(20)).to eq(0)
      end

      it "CHARSET sets charset via interface" do
        expect(interface).to receive(:set_charset).with(2)
        runner.send(:condact_charset, 2)
      end

      it "PARSE reparses buffer" do
        allow(engine).to receive(:quoted_buffer).and_return("new command")
        expect(engine).to receive(:clear_parsed_state)
        expect(engine).to receive(:parse_input).with("new command", is_nested: true)
        expect(engine).to receive(:store_parsed_words)
        expect(engine).to receive(:log_parser_result)
        expect(runner.send(:condact_parse)).to eq(:continue_scan)
      end

      it "PARSE returns ok if buffer is empty" do
        allow(engine).to receive(:quoted_buffer).and_return(nil)
        expect(runner.send(:condact_parse)).to eq(:ok)
      end

      it "returns unsupported for unknown condacts" do
        expect(runner.send(:execute_condact, { "name" => "NOT_A_CONDACT" })).to eq(:unsupported)
        expect(runner.unsupported_condacts.last).to include(name: "NOT_A_CONDACT")
      end

      it "continues process execution after an unsupported condact" do
        engine.game_data["processes"] << {
          "id" => 8,
          "entries" => [
            {
              "verb" => 0,
              "noun" => 0,
              "condacts" => [
                { "name" => "NOT_A_CONDACT" },
                { "name" => "MESSAGE", "params" => [0] },
              ],
            },
          ],
        }

        expect(interface).to receive(:output_text).with("Msg 0", any_args)
        runner.run_process(8, mode: :automatic)
        expect(runner.unsupported_condacts.last).to include(name: "NOT_A_CONDACT")
      end
    end

    describe "RESET" do
      it "moves objects not carried to start location and player to locno" do
        engine.game_data["objects"] = [
          { "location" => 2 }, # Obj 0
          { "location" => 3 },  # Obj 1
        ]
        engine.state.set_object_location(0, 5) # Not carried
        engine.state.set_object_location(1, PAWS::GameState::LOC_CARRIED) # Carried

        catch(:desc_jump) do
          runner.send(:condact_reset, 10)
        end

        expect(engine.state.object_at(0)).to eq(2) # Back to initial
        expect(engine.state.object_at(1)).to eq(10) # Moved to locno
        expect(engine.state.location).to eq(10) # Player moved to locno
      end
    end

    describe "Automatic actions (AUTOW, AUTOR, AUTOP, AUTOT)" do
      before do
        engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      end

      it "AUTOW resolves the object and wears it" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11)

        expect(runner.send(:condact_autow)).to eq(:ok)

        expect(engine.state.object_worn?(1)).to be true
      end

      it "AUTOR resolves the object and removes it" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 12)

        expect(runner.send(:condact_autor)).to eq(:ok)

        expect(engine.state.object_carried?(2)).to be true
      end

      it "AUTOP resolves the object and puts it into the container location" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11)

        expect(runner.send(:condact_autop, 10)).to eq(:ok)

        expect(engine.state.object_at(1)).to eq(10)
      end

      it "AUTOT resolves the object and takes it out of the container location" do
        engine.state.set_object_location(1, 11)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11)

        expect(runner.send(:condact_autot, 11)).to eq(:ok)

        expect(engine.state.object_carried?(1)).to be true
      end

      it "AUTOT prefers a matching object inside the container over an earlier matching object elsewhere" do
        engine.game_data["objects"][0]["noun_id"] = 11
        engine.state.set_object_location(0, PAWS::GameState::LOC_NOT_CREATED)
        engine.state.set_object_location(1, 11)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11)

        expect(runner.send(:condact_autot, 11)).to eq(:ok)

        expect(engine.state.object_at(0)).to eq(PAWS::GameState::LOC_NOT_CREATED)
        expect(engine.state.object_carried?(1)).to be true
      end
    end

    describe "LISTOBJ and LISTAT" do
      before do
        engine.game_data["objects"] = [
          { "name" => "sword", "initial_location" => 2 },
          { "name" => "shield", "initial_location" => 2 },
        ]
        engine.state.reset! # Re-initialize locations
      end

      it "LISTOBJ lists objects at current location" do
        engine.state.location = 2
        expect(engine).to receive(:output_sysmess).with(1, newline: true)
        expect(engine).to receive(:output_text).with("sword", newline: true)
        expect(engine).to receive(:output_text).with("shield", newline: true)
        runner.send(:condact_listobj)
      end

      it "LISTAT lists objects at specified location" do
        expect(engine).to receive(:output_text).with("sword", newline: true)
        expect(engine).to receive(:output_text).with("shield", newline: true)
        runner.send(:condact_listat, 2)
      end

      it "LISTAT outputs SM53 if no objects" do
        expect(engine).to receive(:output_sysmess).with(53)
        expect(runner.send(:condact_listat, 99)).to eq(:ok)
      end

      it "LISTAT continuous mode does not emit a blank line for an empty list terminator" do
        engine.game_data["system_messages"][48] = ""
        engine.state.set_flag(53, 64)

        expect(engine).to receive(:output_text).with("sword", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(47, newline: false).ordered
        expect(engine).to receive(:output_text).with("shield", newline: false).ordered
        expect(engine).not_to receive(:output_text).with("", any_args)
        expect(engine).not_to receive(:output_sysmess).with(48, any_args)

        runner.send(:condact_listat, 2)
      end

      it "LISTAT does not stop later condacts when no objects are found" do
        engine.game_data["processes"] = {
          "0" => {
            "entries" => [
              {
                "verb" => 1,
                "noun" => 255,
                "condacts" => [
                  { "name" => "LISTAT", "params" => [99] },
                  { "name" => "SYSMESS", "params" => [10] },
                  { "name" => "DONE", "params" => [] },
                ],
              },
            ],
          },
        }

        expect(engine).to receive(:output_sysmess).with(53).ordered
        expect(engine).to receive(:output_sysmess).with(10, any_args).ordered

        runner.run_process(0, mode: :response)
      end

      it "LISTOBJ returns ok if empty without outputting" do
        engine.state.location = 99
        expect(engine).not_to receive(:output_sysmess)
        expect(runner.send(:condact_listobj)).to eq(:ok)
      end

      it "LISTOBJ continuous mode with multiple objects uses commas and and" do
        engine.state.location = 2
        engine.game_data["objects"][2] = { "location" => 2, "name" => "helmet", "initial_location" => 2 }
        engine.state.reset!
        engine.state.location = 2

        # bit 6 on
        engine.state.set_flag(53, 64)

        expect(engine).to receive(:output_sysmess).with(1, newline: false).ordered
        expect(engine).to receive(:output_text).with("sword", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(46, newline: false).ordered
        expect(engine).to receive(:output_text).with("shield", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(47, newline: false).ordered
        expect(engine).to receive(:output_text).with("helmet", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(48, newline: true).ordered

        runner.send(:condact_listobj)
      end

      it "LISTOBJ continuous mode lowercases the first visible character after PAWS tags" do
        engine.game_data["objects"] = [
          { "name" => "{ink:green}Una escopeta.", "initial_location" => 2 },
          { "name" => "{ink:green}Una llavecita.", "initial_location" => 2 },
        ]
        engine.state.reset!
        engine.state.location = 2
        engine.state.set_flag(53, 64)

        expect(engine).to receive(:output_sysmess).with(1, newline: false).ordered
        expect(engine).to receive(:output_text).with("{ink:green}una escopeta", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(47, newline: false).ordered
        expect(engine).to receive(:output_text).with("{ink:green}una llavecita", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(48, newline: true).ordered

        runner.send(:condact_listobj)
      end

      it "compound listings trim object descriptions at the first full stop" do
        engine.game_data["objects"] = [
          { "name" => "A small key. Extra detail.", "initial_location" => 2 },
          { "name" => "A brass lamp. It glows.", "initial_location" => 2 },
        ]
        engine.state.reset!
        engine.state.location = 2
        engine.state.set_flag(53, 64)

        expect(engine).to receive(:output_sysmess).with(1, newline: false).ordered
        expect(engine).to receive(:output_text).with("a small key", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(47, newline: false).ordered
        expect(engine).to receive(:output_text).with("a brass lamp", newline: false).ordered
        expect(engine).to receive(:output_sysmess).with(48, newline: true).ordered

        runner.send(:condact_listobj)
      end

      it "LISTOBJ vertical mode" do
        engine.state.location = 2

        # bit 6 off
        engine.state.set_flag(53, 0)

        expect(engine).to receive(:output_sysmess).with(1, newline: true).ordered
        expect(engine).to receive(:output_text).with("sword", newline: true).ordered
        expect(engine).to receive(:output_text).with("shield", newline: true).ordered

        runner.send(:condact_listobj)
      end
    end

    describe "DOALL extensions" do
      it "runs condacts for all objects at a location" do
        engine.game_data["objects"] = [
          { "initial_location" => 5, "noun_id" => 1, "adjective_id" => 2 },
          { "initial_location" => 5, "noun_id" => 3, "adjective_id" => 4 },
        ]
        engine.state.reset!

        expect(runner).to receive(:run_condacts).twice

        runner.send(:condact_doall, 5, [{ "name" => "BEEP" }])

        expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(3) # Last object
      end

      it "handles special locations like 252 (here + carried + worn)" do
        engine.game_data["objects"] = [
          { "initial_location" => 5 },
          { "initial_location" => PAWS::GameState::LOC_CARRIED },
          { "initial_location" => PAWS::GameState::LOC_WORN },
        ]
        engine.state.reset!
        engine.state.location = 5
        expect(runner).to receive(:run_condacts).exactly(3).times
        runner.send(:condact_doall, 252, [{ "name" => "BEEP" }])
      end

      it "handles special location 251 (all objects)" do
        engine.game_data["objects"] = [
          { "initial_location" => 5 },
          { "initial_location" => 6 },
        ]
        engine.state.reset!
        expect(runner).to receive(:run_condacts).exactly(2).times
        runner.send(:condact_doall, 251, [{ "name" => "BEEP" }])
      end

      it "handles special location 253 (worn objects)" do
        engine.game_data["objects"] = [
          { "initial_location" => PAWS::GameState::LOC_WORN },
          { "initial_location" => 5 },
        ]
        engine.state.reset!
        expect(runner).to receive(:run_condacts).once
        runner.send(:condact_doall, 253, [{ "name" => "BEEP" }])
      end

      it "handles special location 254 (carried objects)" do
        engine.game_data["objects"] = [
          { "initial_location" => PAWS::GameState::LOC_CARRIED },
          { "initial_location" => 5 },
        ]
        engine.state.reset!
        expect(runner).to receive(:run_condacts).once
        runner.send(:condact_doall, 254, [{ "name" => "BEEP" }])
      end

      it "handles special location 255 (here objects)" do
        engine.game_data["objects"] = [
          { "initial_location" => 5 },
          { "initial_location" => 6 },
        ]
        engine.state.reset!
        engine.state.location = 5
        expect(runner).to receive(:run_condacts).once
        runner.send(:condact_doall, 255, [{ "name" => "BEEP" }])
      end

      it "skips objects that match EXCEPT NOUN (Noun 2)" do
        engine.game_data["objects"] = [
          { "initial_location" => 5, "noun_id" => 10 },
          { "initial_location" => 5, "noun_id" => 20 },
        ]
        engine.state.reset!
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN2, 10)

        expect(runner).to receive(:run_condacts).once # Only obj 1
        runner.send(:condact_doall, 5, [{ "name" => "BEEP" }])
        expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
      end

      it "re-executes process 0 in response mode if no remaining condacts" do
        engine.game_data["objects"] = [
          { "initial_location" => 5, "noun_id" => 10 },
        ]
        engine.state.reset!

        runner.instance_variable_set(:@process_stack, [0]) # Simulate response mode

        expect(runner).to receive(:run_process).with(0)
        runner.send(:condact_doall, 5, [])
        expect(runner.instance_variable_get(:@done_stack).last).to be true
      end
    end

    describe "MOVE" do
      it "moves in direction if connection exists" do
        engine.state.location = 0
        runner.send(:condact_move, 1)
        expect(engine.state.location).to eq(1)
      end
    end

    describe "SCORE" do
      it "outputs score from flag 30" do
        engine.state.set_flag(30, 85)
        expect(engine).to receive(:output_sysmess).with(21, newline: false)
        expect(engine).to receive(:output_text).with("85", newline: false)
        expect(engine).to receive(:output_sysmess).with(22, newline: true)
        runner.send(:condact_score)
      end
    end

    describe "WHATO wildcards and fallbacks" do
      it "sets referred object to 255 if noun is 0 or 255" do
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 255)
        runner.send(:condact_whato)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(255)
      end

      it "finds matching object by first match if not present anywhere" do
        engine.game_data["objects"] = [
          { "noun_id" => 10, "adjective_id" => 255 },
          { "noun_id" => 10, "adjective_id" => 255 },
        ]
        engine.state.reset!
        # neither is present or carried
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
        engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
        engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 99) # Avoid current_ref matching 0
        runner.send(:condact_whato)
        expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(0)
      end
    end

    describe "MOVE connection failures" do
      it "returns failed for invalid directions" do
        engine.state.location = 0
        expect(runner.send(:condact_move, 99)).to eq(PAWS::ExecutionResult.failed("no connection"))
      end
    end

    describe "logging and verbosity" do
      it "triggers logs when verbosity >= 2 and >= 3" do
        engine.instance_variable_set(:@verbosity, 3)
        expect(engine).to receive(:log).at_least(:once)

        # We can execute a simple condact to trigger log_condact with reminders
        engine.state.set_flag(50, 10)
        runner.send(:log_condact, "SET", [50], :ok)
        runner.send(:log_condact, "ADD", [50, 51], :ok)
        runner.send(:log_condact, "SAME", [50, 51], :ok)
      end

      it "covers extra edge cases for 100% process_runner coverage" do
        # 1. wildcard? with 255
        expect(runner.send(:wildcard?, 255)).to be true

        # 2. resolve_loc with 255, 254, 253
        engine.state.location = 10
        expect(runner.send(:resolve_loc, 255)).to eq(10)
        expect(runner.send(:resolve_loc, 254)).to eq(PAWS::GameState::LOC_CARRIED)
        expect(runner.send(:resolve_loc, 253)).to eq(PAWS::GameState::LOC_WORN)

        # 3. condact_whato first match fallback
        engine.instance_variable_set(:@current_noun, 1) # matches first object
        engine.instance_variable_set(:@current_adject, 255)
        # Ensure it is not present and current_ref is not the object
        engine.state.set_object_location(0, 99)
        engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 99)
        expect(runner.send(:condact_whato)).to eq(:ok)

        # 5. sub-process logs and entry processing logs with verbosity >= 3
        engine.instance_variable_set(:@verbosity, 3)
        allow(engine).to receive(:log)
        # Setup process 99 with a simple entry to trigger processing logs
        engine.game_data["processes"] = { "99" => { "id" => 99, "entries" => [{ "verb" => 1, "noun" => 1, "condacts" => [] }] } }
        runner.run_process(99)

        # 6. log_condact with Array result
        runner.send(:log_condact, "SET", [50], [:failed, "Array error detail"])

        # 7. log_condact with verbosity exactly 2 to cover action reminders
        engine.instance_variable_set(:@verbosity, 2)
        engine.state.set_flag(50, 10)
        runner.instance_variable_set(:@condact_logged, false)
        runner.send(:log_condact, "SET", [50], :ok)
        runner.instance_variable_set(:@condact_logged, false)
        runner.send(:log_condact, "ADD", [50, 51], :ok)

        # 8. nested run_process logging when verbosity >= 2
        engine.game_data["processes"] = {
          "99" => { "id" => 99, "entries" => [{ "verb" => 0, "noun" => 0, "condacts" => [{ "name" => "PROCESS", "params" => [98] }] }] },
          "98" => { "id" => 98, "entries" => [{ "verb" => 0, "noun" => 0, "condacts" => [] }] },
        }
        runner.run_process(99)
      end
    end

    describe "dump_game_state" do
      it "prints game state details" do
        expect(interface).to receive(:output_text).at_least(:once)
        runner.send(:dump_game_state)
      end
    end
  end

  describe "#run_process" do
    it "executes matching entries in :response mode (single match)" do
      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 255)
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 255)
      expect(interface).to receive(:output_text).with("Msg 2", hash_including({}))
      runner.run_process(3, mode: :response)
    end

    describe ":automatic mode" do
      it "executes multiple matching entries when Verb/Noun flags are wildcards" do
        # Process 4 Entry 0 has DONE, so it would stop.
        # Let's use Process 3 which only has one entry, OR process 4 but remove DONE
        # Actually, let's just test that it doesn't filter by Verb.
        # Process 4 Entry 1 has V:20, which is normally not 0.
        # If we run Process 4 and it executes Entry 1, it confirms 0 matching is ignored.
        # Note: Entry 0 of Process 4 has DONE in the new setup, so we use a new process 6 for this test.
        game_data["processes"] << {
          "id" => 6,
          "entries" => [
            { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [0] }] },
            { "verb" => 20, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [1] }] },
          ],
        }
        # Re-init engine to pick up new game_data (or just modify it in place if it works)
        # In engine_spec, it's a let(:game_data), so we might need to recreate the engine or use a different approach.
        # Actually, since runner uses @engine.game_data, we should modify engine.game_data directly.
        if engine.game_data["processes"].is_a?(Array)
          engine.game_data["processes"] << {
            "id" => 6,
            "entries" => [
              { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [0] }] },
              { "verb" => 20, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [1] }] },
            ],
          }
        else
          engine.game_data["processes"]["6"] = {
            "entries" => [
              { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [0] }] },
              { "verb" => 20, "noun" => 0, "condacts" => [{ "name" => "MESSAGE", "params" => [1] }] },
            ],
          }
        end

        expect(interface).to receive(:output_text).with("Msg 0", any_args)
        expect(interface).to receive(:output_text).with("Msg 1", any_args)

        runner.run_process(6, mode: :automatic)
      end

      it "honors explicit Verb/Noun flags in :automatic mode" do
        if engine.game_data["processes"].is_a?(Array)
          engine.game_data["processes"] << {
            "id" => 8,
            "entries" => [
              { "verb" => 1, "noun" => 20, "condacts" => [{ "name" => "MESSAGE", "params" => [0] }] },
              { "verb" => 1, "noun" => 21, "condacts" => [{ "name" => "MESSAGE", "params" => [1] }] },
            ],
          }
        else
          engine.game_data["processes"]["8"] = {
            "entries" => [
              { "verb" => 1, "noun" => 20, "condacts" => [{ "name" => "MESSAGE", "params" => [0] }] },
              { "verb" => 1, "noun" => 21, "condacts" => [{ "name" => "MESSAGE", "params" => [1] }] },
            ],
          }
        end

        engine.state.set_flag(PAWS::GameState::FLAG_VERB, 1)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 20)

        expect(interface).to receive(:output_text).with("Msg 0", any_args)
        expect(interface).not_to receive(:output_text).with("Msg 1", any_args)

        runner.run_process(8, mode: :automatic)
      end

      it "stops execution immediately if DONE is called" do
        # Process 5 has Entry 0 with DONE.
        expect(interface).to receive(:output_text).with("Msg 3", any_args)
        expect(interface).not_to receive(:output_text).with("Msg 4", any_args)

        runner.run_process(5, mode: :automatic)
      end

      it "continues to next entries if DONE is NOT called" do
        if engine.game_data["processes"].is_a?(Array)
          engine.game_data["processes"] << {
            "id" => 7,
            "entries" => [
              { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "SYSMESS", "params" => [10] }] },
              { "verb" => 20, "noun" => 0, "condacts" => [{ "name" => "SYSMESS", "params" => [11] }] },
            ],
          }
        else
          engine.game_data["processes"]["7"] = {
            "entries" => [
              { "verb" => 10, "noun" => 0, "condacts" => [{ "name" => "SYSMESS", "params" => [10] }] },
              { "verb" => 20, "noun" => 0, "condacts" => [{ "name" => "SYSMESS", "params" => [11] }] },
            ],
          }
        end
        expect(interface).to receive(:output_text).with("SysMsg 10", any_args)
        expect(interface).to receive(:output_text).with("SysMsg 11", any_args)

        runner.run_process(7, mode: :automatic)
      end
    end

    describe ":response mode" do
      it "stops after the first match" do
        # Process 4 has two entries.
        # In response mode, it matches the first entry and stops.
        engine.state.set_flag(PAWS::GameState::FLAG_VERB, 10) # Matches entry 0
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10) # Matches entry 0

        expect(interface).to receive(:output_text).with("Msg 0", any_args).once
        expect(interface).not_to receive(:output_text).with("Msg 1", any_args)

        runner.run_process(4, mode: :response)
      end

      it "marks a successfully matched entry as handled even without explicit DONE" do
        engine.state.set_flag(PAWS::GameState::FLAG_VERB, 20)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 20)

        expect(interface).to receive(:output_text).with("Msg 1", any_args)

        runner.run_process(4, mode: :response)

        expect(engine.done_flag).to be true
      end

      it "continues response scanning after a pure LET rewrite" do
        engine.game_data["processes"] << {
          "id" => 10,
          "entries" => [
            { "verb" => 30, "noun" => 50, "condacts" => [
              { "name" => "LET", "params" => [PAWS::GameState::FLAG_NOUN1, 52] },
            ] },
            { "verb" => 30, "noun" => 52, "condacts" => [
              { "name" => "MESSAGE", "params" => [2] },
              { "name" => "DONE", "params" => [] },
            ] },
          ],
        }
        engine.state.set_flag(PAWS::GameState::FLAG_VERB, 30)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 50)

        expect(interface).to receive(:output_text).with("Msg 2", any_args)

        runner.run_process(10, mode: :response)

        expect(engine.done_flag).to be true
      end

      it "continues matching after PARSE reparses a quoted command" do
        game_data["messages"][5] = "Don se levanta."
        game_data["vocabulary"] = [
          { "word" => "sigue", "id" => 59, "type" => 0 },
        ]
        game_data["processes"] << {
          "id" => 9,
          "entries" => [
            { "verb" => 1, "noun" => 1, "condacts" => [
              { "name" => "PARSE", "params" => [] },
            ] },
            { "verb" => 59, "noun" => 255, "condacts" => [
              { "name" => "MESSAGE", "params" => [5] },
              { "name" => "DONE", "params" => [] },
            ] },
          ],
        }
        local_engine = PAWS::Engine.new(game_data, interface)
        local_engine.instance_variable_set(:@running, true)
        local_engine.quoted_buffer = "sigueme"
        local_runner = PAWS::ProcessRunner.new(local_engine)

        expect(interface).to receive(:output_text).with("Don se levanta.", any_args)

        local_runner.run_process(9, mode: :response)

        expect(local_engine.done_flag).to be true
      end

    end

    describe "extra coverage and edge cases" do
      it "handles engine stepping and breakpoints in check_breakpoint" do
        engine.instance_variable_set(:@stepping, true)
        engine.instance_variable_set(:@last_step_point, nil)
        expect(engine).to receive(:breakpoint_reached).at_least(:once)
        runner.send(:check_breakpoint)
      end

      it "continues to the next condact when step is selected in the debugger" do
        engine.state.set_flag(PAWS::GameState::FLAG_VERB, 10)
        engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
        engine.instance_variable_set(:@stepping, true)
        engine.instance_variable_set(:@last_step_point, nil)

        allow(interface).to receive(:get_input).and_return("s", "s", "c")
        expect(interface).to receive(:output_text).with(/BREAKPOINT REACHED/).at_least(:twice)

        runner.run_process(4, mode: :response)
      end

      it "resolves loc 252 to LOC_NOT_CREATED" do
        expect(runner.send(:resolve_loc, 252)).to eq(PAWS::GameState::LOC_NOT_CREATED)
      end

      it "covers copyfb and copybf stubs" do
        expect(runner.send(:condact_copyfb, 1, 2)).to eq(:unsupported)
        expect(runner.send(:condact_copybf, 1, 2)).to eq(:unsupported)
        expect(runner.unsupported_condacts.map { |entry| entry[:name] }).to include("COPYFB", "COPYBF")
      end

      it "covers nested run_process logging and verbosity levels" do
        engine.instance_variable_set(:@verbosity, 3)
        allow(engine).to receive(:log)

        # We manually trigger check_breakpoint with a breakpoint matching
        allow(engine.breakpoint_manager).to receive(:check_execution?).and_return(true)
        expect(engine).to receive(:breakpoint_reached).at_least(:once)

        runner.send(:check_breakpoint)
      end

      it "uses commas in sequential listing for continuous lists" do
        engine.state.set_flag(PAWS::GameState::FLAG_LISTING_CONTROL, 0x40) # continuous listing bit
        engine.state.set_object_location(0, PAWS::GameState::LOC_CARRIED)
        engine.state.set_object_location(1, PAWS::GameState::LOC_CARRIED)
        engine.state.set_object_location(2, PAWS::GameState::LOC_CARRIED)

        allow(engine).to receive(:object_text).with(0).and_return("objeto_a".dup)
        allow(engine).to receive(:object_text).with(1).and_return("objeto_b".dup)
        allow(engine).to receive(:object_text).with(2).and_return("objeto_c".dup)

        allow(engine).to receive(:output_sysmess)
        expect(engine).to receive(:output_sysmess).with(46, any_args).once # ", "
        expect(engine).to receive(:output_sysmess).with(47, any_args).once # " y "

        runner.send(:condact_inven)
      end
    end
  end
end
