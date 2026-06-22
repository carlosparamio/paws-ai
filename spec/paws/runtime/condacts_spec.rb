# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/game_state"
require "paws/runtime/engine"
require "paws/runtime/process_runner"

RSpec.describe "PAWS Condacts" do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Loc 0" }, { "description" => "Loc 1" }, { "description" => "Loc 2" }],
      "messages" => ["Msg 0", "Msg 1", "Msg 2", "Msg 3", "Msg 4"],
      "system_messages" => Array.new(60) { |i| "SysMsg #{i}" },
      "objects" => [
        { "description" => "obj 0", "initially_at" => 1, "weight" => 2, "noun_id" => 10, "adjective_id" => 5 },
        { "description" => "obj 1", "initially_at" => 254, "weight" => 1, "noun_id" => 11, "attrs_lo" => 32768 }, # Wearable (bit 15)
        { "description" => "obj 2", "initially_at" => 253, "weight" => 1, "noun_id" => 12, "attrs_lo" => 32768 },
      ],
      "connections" => [[0, [[1, 1]]]],
      "vocabulary" => [
        { "word" => "RED", "type" => 3, "id" => 5 },     # Adjective 5
        { "word" => "QUICKLY", "type" => 1, "id" => 2 }, # Adverb 2
        { "word" => "ON", "type" => 4, "id" => 3 },      # Prep 3
        { "word" => "BOX", "type" => 2, "id" => 20 },     # Noun 20
      ],
      "processes" => [
        { "id" => 0, "entries" => [
          { "condacts" => [{ "name" => "LET", "params" => [100, 1] }, { "name" => "DONE" }] },
        ] },
        { "id" => 1, "entries" => [
          { "condacts" => [{ "name" => "LET", "params" => [100, 1] }, { "name" => "DONE" }] },
        ] },
      ],
      "defaults" => { "max_carried" => 4 },
    }
  end

  let(:engine) { PAWS::Engine.new(game_data, interface) }
  let(:runner) { PAWS::ProcessRunner.new(engine) }

  before do
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:get_input).and_return("")
    allow(interface).to receive(:clear_screen)
    allow(interface).to receive(:wait_for_key)
    allow(interface).to receive(:flush_input_buffer)
    allow(interface).to receive(:set_colors)
    allow(interface).to receive(:colorize) { |text, *| text }
    allow(interface).to receive(:set_charset)
    allow(interface).to receive(:fmt_val) { |v| v.to_s }
    allow(interface).to receive(:fmt_p) { |p| "P#{p.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_b) { |b| "B#{b.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_c) { |c| "C#{c.to_s.rjust(3, "0")}" }
    allow(interface).to receive(:fmt_flag) { |f| "F#{f}" }
    allow(interface).to receive(:fmt_id) { |id| id.to_s }
    allow(interface).to receive(:fmt_word) { |w| "'#{w}'" }
    allow(interface).to receive(:fmt_condact) { |n| n.to_s }
    runner.instance_variable_set(:@done_stack, [false])
    engine.runner.instance_variable_set(:@done_stack, [false])
    engine.instance_variable_set(:@running, true)
    engine.describe_flag = false
  end

  describe "Group 1: Negative Object Conditions" do
    it "NOTWORN succeeds when object is not worn" do
      expect(runner.send(:condact_notworn, 0)).to eq(:ok)
      engine.state.set_object_location(0, 253)
      expect(runner.send(:condact_notworn, 0)).to be_failed
    end

    it "NOTCARR succeeds when object is not carried" do
      expect(runner.send(:condact_notcarr, 0)).to eq(:ok)
      engine.state.set_object_location(0, 254)
      expect(runner.send(:condact_notcarr, 0)).to be_failed
    end
  end

  describe "Group 2: Vocabulary & Parsing" do
    before do
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 5)
      engine.state.set_flag(PAWS::GameState::FLAG_ADVERB, 2)
      engine.state.set_flag(PAWS::GameState::FLAG_PREP, 3)
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN2, 20)
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT2, 0)
    end

    it "ADJECT1 matches correctly" do
      expect(runner.send(:condact_adject1, 5)).to eq(:ok)
      expect(runner.send(:condact_adject1, 6)).to be_failed
    end

    it "ADVERB matches correctly" do
      expect(runner.send(:condact_adverb, 2)).to eq(:ok)
      expect(runner.send(:condact_adverb, 1)).to be_failed
    end

    it "PREP matches correctly" do
      expect(runner.send(:condact_prep, 3)).to eq(:ok)
      expect(runner.send(:condact_prep, 1)).to be_failed
    end

    it "NOUN2 matches correctly" do
      expect(runner.send(:condact_noun2, 20)).to eq(:ok)
      expect(runner.send(:condact_noun2, 21)).to be_failed
    end

    it "ADJECT2 matches correctly" do
      expect(runner.send(:condact_adject2, 0)).to eq(:ok)
      expect(runner.send(:condact_adject2, 1)).to be_failed
    end

    it "PARSE triggers re-parsing flag" do
      engine.instance_variable_set(:@quoted_buffer, "N")
      runner.send(:condact_parse)
      # PARSE calls parse_input, which doesn't set a flag directly but updates state.
      # We check if store_parsed_words was effectively called via state update.
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(1) # N = Verb 1
    end

    it "CHARSET triggers character set change" do
      expect(interface).to receive(:set_charset).with(1)
      runner.send(:condact_charset, 1)
    end
  end

  describe "Group 3: Math & Flag Operations" do
    before { engine.state.set_flag(100, 50) }

    it "ADD increments flag value" do
      engine.state.set_flag(10, 10)
      runner.send(:condact_add, 100, 10)
      expect(engine.state.get_flag(100)).to eq(60)
    end

    it "SUB decrements flag value" do
      engine.state.set_flag(10, 10)
      runner.send(:condact_sub, 100, 10)
      expect(engine.state.get_flag(100)).to eq(40)
    end

    it "RANDOM sets flag to random value" do
      allow(runner).to receive(:rand).with(256).and_return(7)
      runner.send(:condact_random, 100)
      expect(engine.state.get_flag(100)).to eq(7)
    end
  end

  describe "Group 4: Advanced Object Management" do
    it "LISTOBJ lists objects at location" do
      expect(interface).to receive(:output_text).with(/obj 0/, any_args)
      engine.state.location = 1
      engine.state.set_object_location(0, 1)
      runner.send(:condact_listobj)
    end

    it "LISTAT lists objects at specific location" do
      expect(interface).to receive(:output_text).with(/obj 0/, any_args)
      engine.state.set_object_location(0, 1)
      runner.send(:condact_listat, 1)
    end

    it "WEIGHT gets total carried weight" do
      runner.send(:condact_weight, 200)
      expect(engine.state.get_flag(200)).to eq(2)
    end

    it "WEIGH compares object weight" do
      expect(runner.send(:condact_weigh, 0, 100)).to eq(:ok)
      expect(engine.state.get_flag(100)).to eq(2)
    end

    it "WHATO sets referred object from noun1/adject1" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 5)
      runner.send(:condact_whato)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(0)
    end

    it "PUTO moves referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 0)
      runner.send(:condact_puto, 2)
      expect(engine.state.object_at(0)).to eq(2)
    end

    it "AUTOD drops referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11) # obj 1
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.location = 1
      runner.send(:condact_autod)
      expect(engine.state.object_at(1)).to eq(1)
    end

    it "AUTOG gets referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10) # obj 0
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.location = 1
      engine.state.set_object_location(0, 1)
      runner.send(:condact_autog)
      expect(engine.state.object_at(0)).to eq(254)
    end

    it "AUTOW wears referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11) # obj 1
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.location = 1
      runner.send(:condact_autow)
      expect(engine.state.object_at(1)).to eq(253)
    end

    it "AUTOR removes referred object" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 11) # obj 1
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.set_object_location(1, 253) # Worn
      runner.send(:condact_autor)
      expect(engine.state.object_at(1)).to eq(254) # Back to carried
    end

    it "AUTOP puts referred object into container" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10) # obj 0
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.location = 1
      engine.state.set_object_location(0, 254) # Must be carried
      runner.send(:condact_autop, 100)
      expect(engine.state.object_at(0)).to eq(100)
    end

    it "AUTOT takes referred object out of container" do
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 10) # obj 0
      engine.state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
      engine.state.set_object_location(0, 100)
      runner.send(:condact_autot, 100)
      expect(engine.state.object_at(0)).to eq(254)
    end
  end

  describe "Group 5: Interface & Effects" do
    it "CLS clears screen" do
      expect(interface).to receive(:clear_screen)
      runner.send(:condact_cls)
    end

    it "ANYKEY waits for key" do
      expect(interface).to receive(:wait_for_key)
      runner.send(:condact_anykey)
    end

    it "PAUSE waits for specified time" do
      expect(runner).to receive(:sleep).with(0.1) # PAUSE 5 = 5/50s = 0.1s
      runner.send(:condact_pause, 5)
    end

    it "NEWLINE outputs newline" do
      expect(interface).to receive(:output_text).with("", any_args)
      runner.send(:condact_newline)
    end

    it "PRINT outputs flag value" do
      engine.state.set_flag(1, 42)
      expect(interface).to receive(:output_text).with("42", any_args)
      runner.send(:condact_print, 1)
    end

    it "SYSMESS outputs system message" do
      expect(interface).to receive(:output_text).with("SysMsg 10", hash_including(newline: false))
      runner.send(:condact_sysmess, 10)
    end

    it "BEEP is an explicit optional no-op" do
      expect(runner.send(:condact_beep, 1, 1)).to eq(:ok)
    end

    it "PAPER sets paper color" do
      expect(interface).to receive(:set_colors).with(hash_including(paper: "blue"))
      runner.send(:condact_paper, 1) # 1 = Blue
    end

    it "INK sets ink color" do
      expect(interface).to receive(:set_colors).with(hash_including(ink: "red"))
      runner.send(:condact_ink, 2) # 2 = Red
    end

    it "BORDER reports unsupported" do
      expect(runner.send(:condact_border, 1)).to eq(:unsupported)
    end

    it "LINE reports unsupported" do
      expect(runner.send(:condact_line, 1)).to eq(:unsupported)
    end

    it "PICTURE reports unsupported" do
      expect(runner.send(:condact_picture, 1)).to eq(:unsupported)
    end

    it "PROMPT sets prompt flag" do
      runner.send(:condact_prompt, 5)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_PROMPT)).to eq(5)
    end

    it "GRAPHIC reports unsupported" do
      expect(runner.send(:condact_graphic, 1)).to eq(:unsupported)
    end

    it "PRINTAT reports unsupported" do
      expect(runner.send(:condact_printat, 1, 1)).to eq(:unsupported)
    end
  end

  describe "Group 6: Execution Flow & Misc" do
    it "PROCESS runs another process table" do
      runner.send(:condact_process, 1)
      expect(engine.state.get_flag(100)).to eq(1)
    end

    it "SAVEAT / BACKAT manage location bookmarks" do
      engine.state.location = 2
      runner.send(:condact_saveat)
      engine.state.location = 1
      runner.send(:condact_backat)
      expect(engine.state.location).to eq(2)
    end

    it "RESET resets engine state" do
      engine.state.location = 1
      catch(:desc_jump) { runner.send(:condact_reset, 2) }
      expect(engine.state.location).to eq(2)
    end

    it "MODE sets screen mode flag" do
      runner.send(:condact_mode, 1, 0)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_SCREEN_MODE)).to eq(1)
    end

    it "TIME sets timeout flags" do
      runner.send(:condact_time, 10, 128)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH)).to eq(10)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(128)
    end

    it "EXTERN reports unsupported" do
      expect(runner.send(:condact_extern, 1)).to eq(:unsupported)
    end

    it "TIMEOUT checks timeout flag" do
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 128)
      expect(runner.send(:condact_timeout)).to eq(:ok)
    end

    it "NEWTEXT clears phrases" do
      expect(engine).to receive(:clear_phrases)
      runner.send(:condact_newtext)
    end

    it "ABILITY sets carrying limits" do
      runner.send(:condact_ability, 10, 100)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_MAX_CARRIED)).to eq(10)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_MAX_WEIGHT)).to eq(100)
    end

    it "PROTECT is an explicit optional no-op" do
      expect(runner.send(:condact_protect)).to eq(:ok)
    end

    it "QUIT returns :ok on YES and :failed on NO" do
      allow(interface).to receive(:wait_for_key).and_return("s")
      expect(engine).to receive(:stop)
      expect(runner.send(:condact_quit)).to eq(:ok)

      allow(interface).to receive(:wait_for_key).and_return("n")
      expect(runner.send(:condact_quit)).to eq(:failed)
    end

    it "END returns :abort and stops/restarts engine" do
      allow(interface).to receive(:wait_for_key).and_return("n") # stop
      expect(engine).to receive(:stop)
      expect(runner.send(:condact_end)).to eq(:abort)

      allow(interface).to receive(:wait_for_key).and_return("s") # restart
      expect(engine).to receive(:restart)
      expect(runner.send(:condact_end)).to eq(:abort)
    end
  end
end
