# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/game_state"
require "paws/runtime/engine"
require "paws/runtime/process_runner"

RSpec.describe PAWS::Engine do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [
        { "description" => "Pantalla de título" },
        { "description" => "Estás en una habitación." },
        { "description" => "Estás en un pasillo." },
      ],
      "messages" => ["Mensaje 0", "Mensaje 1"],
      "system_messages" => [
        "",                      # 0
        "También puedes ver:",   # 1
        nil, nil, nil, nil,
        "No puedes ir por ahí.", # 6
        nil,
        "Está muy oscuro.",      # 8
        "No llevas nada.",       # 9
        "Llevas:",                # 10
      ],
      "objects" => [
        { "description" => "una llave", "initially_at" => 1, "noun" => 20, "adjective" => 255 },
      ],
      "connections" => [
        [1, [[1, 2]]], # loc 1: dir 1 -> 2
        [2, [[2, 1]]],  # loc 2: dir 2 -> 1
      ],
      "vocabulary" => [
        { "word" => "norte", "id" => 1, "type_id" => 2 },
        { "word" => "n", "id" => 1, "type_id" => 2 },
        { "word" => "sur", "id" => 2, "type_id" => 2 },
        { "word" => "s", "id" => 2, "type_id" => 2 },
        { "word" => "coger", "id" => 14, "type_id" => 0 },
        { "word" => "llave", "id" => 20, "type_id" => 2 },
      ],
      "processes" => [
        { "id" => 0, "entries" => [] },
        { "id" => 1, "entries" => [] },
        { "id" => 2, "entries" => [] },
      ],
      "defaults" => { "max_carried" => 4 },
    }
  end

  subject(:engine) { described_class.new(game_data, interface) }

  before do
    allow(interface).to receive(:output_text)
    allow(interface).to receive(:output_debug)
    allow(interface).to receive(:get_input).and_return("n")
    allow(interface).to receive(:get_player_input).and_return("n")
    allow(interface).to receive(:input_buffer_empty?).and_return(true)
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
  end

  describe "#initialize" do
    it "creates a GameState" do
      expect(engine.state).to be_a(PAWS::GameState)
    end

    it "starts with describe_flag true" do
      expect(engine.describe_flag).to be true
    end

    it "starts with done_flag false" do
      expect(engine.done_flag).to be false
    end
  end

  describe "#describe_location" do
    before { engine.state.location = 1 }

    it "outputs location description" do
      expect(interface).to receive(:output_text).with("Estás en una habitación.", hash_including({}))
      engine.describe_location
    end

    it "does not list objects (handled by process 1)" do
      # LISTOBJ is called from process 1, not describe_location
      expect(interface).to receive(:output_text).with("Estás en una habitación.", hash_including({}))
      expect(interface).not_to receive(:output_text).with("También puedes ver:")
      engine.describe_location
    end

    it "skips location 0 (title screen)" do
      engine.state.location = 0
      expect(interface).not_to receive(:output_text).with("Pantalla de título")
      engine.describe_location
    end

    it "shows dark message when dark" do
      engine.state.set_flag(PAWS::GameState::FLAG_DARK, 1)
      # Asegurar que el objeto 0 (luz) no esté presente
      engine.state.set_object_location(0, PAWS::GameState::LOC_NOT_CREATED)
      expect(interface).to receive(:output_text).with("Está muy oscuro.", hash_including({}))
      engine.describe_location
    end
  end

  describe "parser" do
    it "parses direction nouns as verbs" do
      engine.send(:parse_input, "norte")
      engine.send(:store_parsed_words)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(1)
    end

    it "parses verb + noun" do
      engine.send(:parse_input, "coger llave")
      engine.send(:store_parsed_words)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
    end

    it "truncates words to 5 characters" do
      expect(engine.send(:find_vocabulary, "norte")).to be_truthy
      expect(engine.send(:find_vocabulary, "nortex")).to be_truthy # truncated to 'norte'
    end

    it "falls back to traditional parser if AIParser returns nil" do
      ai_parser = instance_double(PAWS::AIParser, parse: nil)
      engine = described_class.new(game_data, interface, ai_enabled: true, ai_parser: ai_parser)

      engine.send(:parse_input, "coger llave")
      engine.send(:store_parsed_words)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
      expect(ai_parser).to have_received(:parse).with("coger llave", context: hash_including(is_nested: false))
    end

    it "falls back to traditional parser if AIParser raises" do
      ai_parser = instance_double(PAWS::AIParser)
      allow(ai_parser).to receive(:parse).and_raise(RuntimeError, "bad AI response")
      engine = described_class.new(game_data, interface, verbosity: 1, ai_enabled: true, ai_parser: ai_parser)

      expect { engine.send(:parse_input, "coger llave") }.not_to raise_error

      engine.send(:store_parsed_words)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
      expect(interface).to have_received(:output_debug).with(include("AI interpretation failed"), 1)
    end

    it "falls back to traditional parser if AIParser returns an empty command" do
      ai_parser = instance_double(PAWS::AIParser, parse: PAWS::ParsedCommand.new)
      engine = described_class.new(game_data, interface, ai_enabled: true, ai_parser: ai_parser)

      engine.send(:parse_input, "coger llave")
      engine.send(:store_parsed_words)

      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14)
      expect(engine.state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
    end
  end

  describe "#try_direction_movement" do
    before do
      engine.state.location = 1
      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 1) # norte
    end

    it "moves to connected location" do
      engine.send(:try_direction_movement)
      expect(engine.state.location).to eq(2)
    end

    it "sets describe_flag after movement" do
      engine.instance_variable_set(:@describe_flag, false)
      engine.send(:try_direction_movement)
      expect(engine.describe_flag).to be true
    end

    it "returns :failed for invalid direction" do
      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 2) # sur (no connection)
      expect(engine.send(:try_direction_movement)).to eq(:failed)
      expect(engine.state.location).to eq(1) # unchanged
    end
  end

  describe "#autodecrement_flags" do
    it "decrements flags > 0" do
      engine.state.set_flag(5, 3)
      engine.state.set_flag(6, 1)
      engine.state.set_flag(7, 0)

      engine.send(:autodecrement_flags, 5..7)

      expect(engine.state.get_flag(5)).to eq(2)
      expect(engine.state.get_flag(6)).to eq(0)
      expect(engine.state.get_flag(7)).to eq(0)
    end
  end

  describe "#set_done / #set_notdone" do
    it "sets done_flag" do
      engine.set_done
      expect(engine.done_flag).to be true
    end

    it "clears done_flag" do
      engine.set_done
      engine.set_notdone
      expect(engine.done_flag).to be false
    end
  end

  describe "#output_message" do
    it "outputs message by id" do
      expect(interface).to receive(:output_text).with("Mensaje 1", hash_including({}))
      engine.output_message(1)
    end
  end

  describe "#output_sysmess" do
    it "outputs system message by id" do
      expect(interface).to receive(:output_text).with("No puedes ir por ahí.", hash_including({}))
      engine.output_sysmess(6)
    end
  end

  describe "#get_prompt_text" do
    it "returns specific prompt from system message with trailing space" do
      engine.state.set_flag(PAWS::GameState::FLAG_PROMPT, 1) # "También puedes ver:"
      expect(engine.send(:get_prompt_text)).to eq("También puedes ver: ")
    end

    it "randomizes between 2,3,4,5 when flag is 0" do
      engine.state.set_flag(PAWS::GameState::FLAG_PROMPT, 0)
      expect(engine.send(:get_prompt_text)).to be_a(String)
    end
  end

  describe "object substitution in text" do
    it "substitutes _ with referred object name" do
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 0) # Objeto 0 (llave)
      expect(interface).to receive(:output_text).with("Coges una llave.", hash_including({}))
      engine.output_text("Coges _.")
    end

    it "uses object labels without description tails for placeholders" do
      engine.game_data["objects"][0]["name"] = "{2} una llave. Algo más."
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 0)

      expect(interface).to receive(:output_text).with("Coges {2}una llave.", hash_including({}))
      engine.output_text("Coges _.")
    end

    it "substitutes _ with empty string when no object referred" do
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 255)
      expect(interface).to receive(:output_text).with("Coges .", hash_including({}))
      engine.output_text("Coges _.")
    end
  end

  describe "#main_loop flow" do
    it "executes description if describe_flag is true" do
      engine.describe_flag = true
      # Usar un mock simple para order_loop para evitar efectos secundarios
      allow(engine).to receive(:order_loop)
      expect(engine).to receive(:description_phase)
      engine.main_loop
    end

    it "skips description if describe_flag is false" do
      engine.describe_flag = false
      allow(engine).to receive(:order_loop)
      expect(engine).not_to receive(:description_phase)
      engine.main_loop
    end
  end

  describe "#input_phase" do
    it "decrements timer flags" do
      engine.state.set_flag(5, 10)
      allow(interface).to receive(:get_player_input).and_return("n")
      engine.input_phase
      expect(engine.state.get_flag(5)).to eq(9)
    end

    it "skips fallback response if engine is stopped during response phase" do
      # Simulate a process 0 that calls stop
      allow(engine).to receive(:run_process).with(0, mode: :response) do
        engine.stop
      end

      expect(engine).not_to receive(:fallback_response)
      engine.response_phase
    end

    it "splits multiple commands" do
      allow(interface).to receive(:get_player_input).and_return("coger llave. sur")
      engine.input_phase
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(14) # coger

      # La siguiente llamada debería procesar 'sur'
      engine.input_phase
      expect(engine.state.get_flag(PAWS::GameState::FLAG_VERB)).to eq(2) # sur
    end

    it "enters interactive debug repl when !debug is typed" do
      engine.instance_variable_set(:@debug_enabled, true)

      # First it gets '!debug', which triggers breakpoint_reached.
      # Then we make it return :timeout so the loop breaks.
      allow(interface).to receive(:get_player_input).and_return("!debug", :timeout)

      # Intercept breakpoint_reached to check it was called.
      expect(engine).to receive(:breakpoint_reached).with(any_args).and_call_original
      allow(engine.debugger).to receive(:breakpoint_reached) # Prevent actual debugger from blocking test

      engine.input_phase
    end
  end

  describe "#on_state_change" do
    let(:breakpoint_manager) { engine.breakpoint_manager }

    it "triggers debugger when flag breakpoint reached" do
      breakpoint_manager.parse_line("F60=42")
      expect(engine.debugger).to receive(:breakpoint_reached)
      engine.state.set_flag(60, 42)
    end

    it "triggers debugger when location breakpoint reached" do
      breakpoint_manager.parse_line("L2")
      expect(engine.debugger).to receive(:breakpoint_reached)
      engine.state.location = 2
    end
  end

  describe "#load_flag_descriptions" do
    it "parses flag descriptions from file" do
      temp_file = "temp_flags.txt"
      File.write(temp_file, "60 User Flag 60\n61 User Flag 61\n")

      descriptions = engine.load_flag_descriptions(temp_file)
      expect(descriptions[60]).to eq("User Flag 60")
      expect(descriptions[61]).to eq("User Flag 61")

      File.delete(temp_file)
    end
  end

  describe "debugger delegation" do
    it "delegates dump methods to the debugger instance" do
      expect(engine.debugger).to receive(:dump_state)
      expect(engine.debugger).to receive(:dump_locations).with(1)
      expect(engine.debugger).to receive(:dump_objects).with(2)
      expect(engine.debugger).to receive(:dump_connections).with(3)
      expect(engine.debugger).to receive(:dump_vocabulary).with(nil)
      expect(engine.debugger).to receive(:dump_engine_info)

      engine.dump_state
      engine.dump_locations(1)
      engine.dump_objects(2)
      engine.dump_connections(3)
      engine.dump_vocabulary(nil)
      engine.dump_engine_info
    end
  end

  describe "#order_loop outcomes" do
    before do
      engine.instance_variable_set(:@running, true)
    end

    it "handles :timeout outcome" do
      expect(engine).to receive(:input_phase).and_return(:timeout)
      expect(engine).to receive(:output_sysmess).with(35, newline: true)
      engine.order_loop
    end

    it "handles :not_found outcome" do
      expect(engine).to receive(:input_phase).and_return(:not_found)
      expect(engine).to receive(:output_sysmess).with(6, newline: true)
      engine.order_loop
    end
  end

  describe "state change logging under high verbosity" do
    before do
      engine.instance_variable_set(:@verbosity, 3)
    end

    it "logs flag changes" do
      expect(engine).to receive(:log).with(/F.*60.*changed to.*42/, 3)
      engine.on_state_change(:flag, 60, 0, 42)
    end

    it "logs object location changes" do
      expect(engine).to receive(:log).with(/Object.*1.*moved to.*254/, 3)
      engine.on_state_change(:object, 1, 254)
    end
  end

  describe "extra debugger delegations" do
    it "delegates dump_system_messages" do
      expect(engine.debugger).to receive(:dump_system_messages).with(5)
      engine.dump_system_messages(5)
    end
  end

  describe "traditional parser fallback and quoted strings" do
    it "parses quoted string buffer" do
      engine.instance_variable_set(:@ai_enabled, false)
      engine.parse_input('decir "hola mundo"')
      expect(engine.quoted_buffer).to eq("hola mundo")
    end
  end

  describe "extra engine logic coverage" do
    it "handles log helper and run loop stopping" do
      engine.instance_variable_set(:@verbosity, 3)
      engine.instance_variable_set(:@runner, double("runner", ensure_condact_logged: true))
      expect(interface).to receive(:output_debug).at_least(:once)
      engine.log("test log", 2)

      # Test run loop stopping immediately
      engine.instance_variable_set(:@running, true)
      expect(engine).to receive(:main_loop) { engine.stop }
      engine.run
      expect(engine.running?).to be false
    end

    it "handles restart" do
      expect(engine.state).to receive(:reset!).once
      engine.restart
      expect(engine.running?).to be true
      expect(engine.instance_variable_get(:@first_turn)).to be true
      expect(engine.describe_flag).to be true
      expect(engine.done_flag).to be false
    end

    it "delegates stack, breakpoints, current_process and messages and handles pending breakpoints" do
      engine.debugger.singleton_class.send(:public, :dump_current_process)
      expect(engine.debugger).to receive(:dump_stack).once
      expect(engine.debugger).to receive(:dump_breakpoints).once
      expect(engine.debugger).to receive(:dump_current_process).with(1, 2, 3).once
      expect(engine.debugger).to receive(:dump_messages).with(10).once

      engine.dump_stack
      engine.dump_breakpoints
      engine.dump_current_process(1, 2, 3)
      engine.dump_messages(10)

      # Pending breakpoint
      engine.instance_variable_set(:@pending_breakpoint, { p: 1, b: 2, c: 3, reason: "Test" })
      expect(engine.debugger).to receive(:breakpoint_reached).with(1, 2, 3, reason: "Test").once
      engine.check_pending_breakpoint
    end

    it "handles dark state in input phase" do
      engine.state.set_flag(PAWS::GameState::FLAG_DARK, 1)
      engine.state.set_flag(9, 5)
      engine.state.set_flag(10, 5)
      allow(interface).to receive(:get_player_input).and_return(nil)
      engine.input_phase
      expect(engine.state.get_flag(9)).to eq(4)
      expect(engine.state.get_flag(10)).to eq(4)
    end

    it "clears phrases" do
      engine.instance_variable_set(:@phrase_queue, ["phrase1"])
      engine.clear_phrases
      expect(engine.instance_variable_get(:@phrase_queue)).to be_empty
    end

    it "handles AI parser with zeroed outputs and direction noun conversion" do
      ai_command = PAWS::ParsedCommand.from_ai_result(
        "verb" => 0,
        "noun1" => 5,
        "noun2" => 0,
        "adject1" => 0,
        "adject2" => 0,
        "adverb" => 0,
        "prep" => 0,
        "quoted_command" => "test",
      )
      ai_parser = instance_double(PAWS::AIParser, parse: ai_command)
      engine = described_class.new(game_data, interface, ai_enabled: true, ai_parser: ai_parser)

      engine.parse_input("test")
      expect(engine.instance_variable_get(:@current_verb)).to eq(5)
      expect(engine.instance_variable_get(:@current_noun)).to eq(5)
      expect(engine.quoted_buffer).to eq("test")
    end

    it "handles traditional parser with adverbs, adjective, prepositions, and pronouns" do
      engine.instance_variable_set(:@ai_enabled, false)
      engine.game_data["vocabulary"] << { "word" => "rapid", "id" => 1, "type_id" => 1 }
      engine.game_data["vocabulary"] << { "word" => "rojo", "id" => 2, "type_id" => 3 }
      engine.game_data["vocabulary"] << { "word" => "con", "id" => 3, "type_id" => 4 }
      engine.game_data["vocabulary"] << { "word" => "ello", "id" => 4, "type_id" => 6 }

      expect(engine).to receive(:resolve_pronoun).with(4).once
      engine.parse_input("rapid rojo con ello")
      expect(engine.instance_variable_get(:@current_adverb)).to eq(1)
      expect(engine.instance_variable_get(:@current_adject)).to eq(2)
      expect(engine.instance_variable_get(:@current_prep)).to eq(3)
    end

    it "handles state setter logging and getters" do
      engine.instance_variable_set(:@verbosity, 2)
      expect(engine).to receive(:log).at_least(:once)
      engine.done_flag = true
      engine.describe_flag = true
      engine.skip_clear_screen = true

      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 255)
      engine.state.set_flag(PAWS::GameState::FLAG_NOUN1, 255)
      expect(engine.current_verb).to eq(255)
      expect(engine.current_noun).to eq(255)
    end

    it "processes process intent context and scanning condacts for vocab" do
      engine.game_data["processes"] = {
        "5" => {
          "entries" => [
            {
              "verb" => 10,
              "noun" => 20,
              "condacts" => [
                { "name" => "ADJECT1", "params" => [30] },
                { "name" => "NOUN2", "params" => [40] },
                { "name" => "ADVERB", "params" => [50] },
                { "name" => "PREP", "params" => [60] },
              ],
            },
          ],
        },
      }
      res = engine.get_process_intent_context(5)
      expect(res.any?).to be true
    end

    it "handles fallback_response movement and output" do
      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 1) # direction
      engine.state.location = 1
      expect(engine.fallback_response).to eq(:moved)

      engine.state.set_flag(PAWS::GameState::FLAG_VERB, 99) # invalid verb
      expect(interface).to receive(:output_text).at_least(:once)
      engine.fallback_response
    end

    it "handles light_present? and get_prompt_text hash" do
      engine.game_data["objects"] << { "is_light" => true }
      expect(engine.light_present?).to be false

      # get_prompt_text with hash
      engine.state.set_flag(PAWS::GameState::FLAG_PROMPT, 1)
      engine.game_data["system_messages"][1] = { "text" => "custom prompt" }
      expect(engine.get_prompt_text).to eq("custom prompt ")
    end

    it "handles on_state_change object/flag pending breakpoint" do
      allow(interface).to receive(:output_debug)
      engine.instance_variable_set(:@verbosity, 3)
      runner = double("runner", executing_condact?: true, process_stack: [1], entry_index_stack: [2], condact_index_stack: [3], ensure_condact_logged: nil)
      engine.instance_variable_set(:@runner, runner)

      engine.breakpoint_manager.breakpoints[:flags] << { flag: 50, op: "=", value: 10 }
      engine.on_state_change(:flag, 50, 0, 10)
      expect(engine.instance_variable_get(:@pending_breakpoint)).not_to be_nil

      engine.instance_variable_set(:@pending_breakpoint, nil)
      engine.breakpoint_manager.breakpoints[:objects] << { object: 0, location: "1" }
      engine.on_state_change(:object, 0, "1")
      expect(engine.instance_variable_get(:@pending_breakpoint)).not_to be_nil
    end

    it "sets correct timeout value for player input" do
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH, 2)
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 1)
      expect(interface).to receive(:get_player_input).with(hash_including(timeout: 2.56)).and_return("n")
      engine.input_phase
    end

    it "does not time out between keypresses when the PAWS option only enables first-character timeout" do
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH, 2)
      engine.state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 1)
      allow(interface).to receive(:input_buffer_empty?).and_return(false)

      expect(interface).to receive(:get_player_input).with(hash_including(timeout: nil)).and_return("n")
      engine.input_phase
    end

    it "stops engine if input is nil (EOF)" do
      expect(interface).to receive(:get_player_input).and_return(nil)
      expect(engine).to receive(:stop).once
      engine.input_phase
    end

    it "splits multiple phrases using y, e, or and" do
      expect(interface).to receive(:get_player_input).and_return("coger llave y coger espada and sur e ir norte")
      engine.input_phase
      expect(engine.instance_variable_get(:@phrase_queue)).to eq(["coger espada", "sur", "ir norte"])
    end

    it "handles quoted buffer with trailing text" do
      engine.instance_variable_set(:@ai_enabled, false)
      engine.parse_input('coger "hola" extra')
      expect(engine.quoted_buffer).to eq('hola" extra')
      expect(engine.instance_variable_get(:@current_verb)).to eq(14)
    end

    it "uses randomized system message if prompt is 0" do
      engine.state.set_flag(PAWS::GameState::FLAG_PROMPT, 0)
      allow(engine).to receive(:rand).with(100).and_return(15, 45, 75, 95)
      4.times { expect(engine.get_prompt_text).to be_a(String) }
    end

    it "handles double nouns, adjectives, and pronoun resolution in parser" do
      # Set up double nouns/adjectives
      engine.instance_variable_set(:@ai_enabled, false)
      engine.instance_variable_set(:@current_verb, 99)
      allow(engine).to receive(:find_vocabulary).with("word1").and_return({ "type_id" => 2, "id" => 21 }) # noun 1 >= 20
      allow(engine).to receive(:find_vocabulary).with("word2").and_return({ "type_id" => 2, "id" => 22 }) # noun 2
      allow(engine).to receive(:find_vocabulary).with("word3").and_return({ "type_id" => 3, "id" => 3 }) # adjective 1
      allow(engine).to receive(:find_vocabulary).with("word4").and_return({ "type_id" => 3, "id" => 4 }) # adjective 2

      engine.parse_input("word1 word2 word3 word4")
      expect(engine.instance_variable_get(:@current_noun)).to eq(21)
      expect(engine.instance_variable_get(:@current_noun2)).to eq(22)
      expect(engine.instance_variable_get(:@current_adject)).to eq(3)
      expect(engine.instance_variable_get(:@current_adject2)).to eq(4)

      # Pronoun resolution
      engine.state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 42)
      engine.state.set_flag(PAWS::GameState::FLAG_PRONOUN_ADJECT, 12)
      engine.send(:resolve_pronoun, 1)
      expect(engine.instance_variable_get(:@current_noun)).to eq(42)
      expect(engine.instance_variable_get(:@current_adject)).to eq(12)
    end

    it "logs state change for describe_flag under verbosity" do
      engine.instance_variable_set(:@verbosity, 3)
      expect(engine).to receive(:log).at_least(:once)
      engine.describe_flag = false
    end

    it "handles output_sysmess with text Hash structure" do
      engine.game_data["system_messages"][99] = { "text" => "Hello _ World" }
      expect(interface).to receive(:output_text).with("Hello object World", any_args)
      engine.output_sysmess(99, placeholder: "object")
    end

    it "calls breakpoint_reached directly during on_state_change if not executing condact" do
      allow(interface).to receive(:output_debug)
      engine.instance_variable_set(:@verbosity, 3)
      runner = double("runner", executing_condact?: false, process_stack: [], entry_index_stack: [], condact_index_stack: [], ensure_condact_logged: nil)
      engine.instance_variable_set(:@runner, runner)

      engine.breakpoint_manager.breakpoints[:objects] << { object: 0, location: "1" }
      expect(engine).to receive(:breakpoint_reached).at_least(:once)
      engine.on_state_change(:object, 0, "1")
    end
  end

  describe "#vocabulary_word" do
    it "returns wildcards for 0, 1, and 255" do
      expect(engine.vocabulary_word(1, 0)).to eq("*")
      expect(engine.vocabulary_word(0, 0)).to eq("*")
      expect(engine.vocabulary_word(255, 0)).to eq("_")
    end

    it "returns upcase word from vocabulary if found by type" do
      expect(engine.vocabulary_word(14, 0)).to eq("COGER")
    end

    it "returns ID string if not found" do
      expect(engine.vocabulary_word(999, 0)).to eq("ID999")
    end
  end

  describe "#get_ai_context" do
    it "gathers all relevant state and vocabulary information" do
      engine.state.set_object_location(0, 254) # carried
      context = engine.get_ai_context
      expect(context[:game_title]).to eq("PAWS Adventure")
      expect(context[:inventory]).to eq(["una llave"])
      expect(context[:vocabulary]).not_to be_empty
      expect(context).to have_key(:intent_index)
    end
  end

  describe "#get_full_intent_index" do
    let(:process_entries) do
      [
        {
          "verb" => 14, "verb_name" => "COGER", "noun" => 20, "noun_name" => "LLAVE",
          "condacts" => [{ "opcode" => 16, "name" => "ADJECT1", "params" => [50] }],
        },
        {
          "verb" => 14, "verb_name" => "COGER", "noun" => 20, "noun_name" => "LLAVE",
          "condacts" => [{ "opcode" => 16, "name" => "ADJECT1", "params" => [50] }],
        },
        {
          "verb" => 14, "verb_name" => "COGER", "noun" => 255, "noun_name" => "_",
          "condacts" => [{ "opcode" => 17, "name" => "ADVERB", "params" => [60] }],
        },
        {
          "verb" => 1, "verb_name" => "*", "noun" => 1, "noun_name" => "*",
          "condacts" => [],
        },
      ]
    end
    let(:game_data) do
      super().merge(
        "vocabulary" => super()["vocabulary"] + [
          { "word" => "ligero", "id" => 50, "type_id" => 3 },
          { "word" => "rapido", "id" => 60, "type_id" => 1 },
        ],
        "processes" => [
          { "id" => 0, "entries" => process_entries.first(2) },
          { "id" => 2, "entries" => process_entries[2..] },
        ],
      )
    end

    it "dedupes verb+noun pairs across processes" do
      engine = described_class.new(game_data, interface)
      index = engine.get_full_intent_index

      pair_keys = index.map { |entry| [entry[:verb], entry[:noun]] }
      expect(pair_keys).to contain_exactly(["COGER", "LLAVE"], ["COGER", "_"])
    end

    it "merges adjective checks from every block that shares a pair" do
      engine = described_class.new(game_data, interface)
      index = engine.get_full_intent_index
      take_llave = index.find { |entry| entry[:verb] == "COGER" && entry[:noun] == "LLAVE" }

      expect(take_llave[:checks]).to contain_exactly(
        hash_including(type: "adjective1", word: "LIGERO"),
      )
    end

    it "skips fully wildcard entries" do
      engine = described_class.new(game_data, interface)
      index = engine.get_full_intent_index

      expect(index.map { |entry| [entry[:verb], entry[:noun]] }).not_to include(["*", "*"])
    end
  end
end
