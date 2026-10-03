# frozen_string_literal: true

require_relative "game_state"
require_relative "engine_phases/description_phase"
require_relative "engine_phases/input_phase"
require_relative "engine_phases/movement_fallback"
require_relative "engine_phases/response_phase"
require_relative "engine_phases/turn_loop"
require_relative "process_runner"
require_relative "../game_data/repository"
require_relative "../parsing/parsed_command"
require_relative "../parsing/classic_parser"
require_relative "../parsing/ai_parser"
require_relative "../debug/breakpoint_manager"
require_relative "../debug/debugger"
require_relative "../debug/state_history"

module PAWS
  # Main coordinator for the PAWS runtime.
  # Engine owns the game loop, player input phases, parser selection, state
  # change observation, breakpoint integration, and high-level output helpers.
  # It deliberately delegates process-table execution to ProcessRunner and
  # concrete condact behavior to registered handlers.
  #
  # Architecturally this is the application service/facade for one running game:
  # UI and persistence are ports on Interface, parser implementations are
  # replaceable collaborators, and the debugger is another adapter over the same
  # runtime state rather than a privileged pile of private calls.
  class Engine
    attr_reader :state, :game_data, :game_data_repository, :interface, :running, :breakpoint_manager, :debugger, :skip_clear_screen, :runner, :state_history
    attr_reader :describe_flag, :done_flag, :last_step_point
    attr_accessor :quoted_buffer, :stepping, :verbosity, :abort_execution, :step_resume_after

    HISTORY_MAX_SIZE = 100

    def initialize(game_data, interface, verbosity: 0, breakpoints_file: nil, skip_clear_screen: false, flags_desc_file: nil, ai_enabled: false, debug_mode: false, history_size: StateHistory::DEFAULT_CAPACITY, classic_parser: nil, ai_parser: nil)
      @verbosity = verbosity
      @breakpoint_manager = BreakpointManager.new(breakpoints_file)
      @flag_descriptions = load_flag_descriptions(flags_desc_file)
      @skip_clear_screen = skip_clear_screen
      @game_data_repository = GameData::Repository.new(game_data)
      @game_data = @game_data_repository.to_h
      @interface = interface
      @runner = ProcessRunner.new(self)
      @state = GameState.new(@game_data)
      @state.on_change = method(:on_state_change)
      @description_phase = DescriptionPhase.new(self)
      @input_phase = InputPhase.new(self)
      @movement_fallback = MovementFallback.new(self)
      @response_phase = ResponsePhase.new(self)
      @turn_loop = TurnLoop.new(self)
      @pending_breakpoint = nil
      @phrase_queue = []
      @history_buffer = []
      @ai_enabled = ai_enabled
      @classic_parser = classic_parser
      @ai_parser = ai_parser
      self.done_flag = false
      self.describe_flag = true
      @running = false
      @quoted_buffer = nil
      @stepping = !!debug_mode
      @debug_enabled = !!debug_mode
      @state_history = debug_mode ? StateHistory.new(capacity: history_size) : nil
      @debugger = Debugger.new(self)
      @last_step_point = nil
      @step_resume_after = nil
      @restart_requested = false

      apply_defaults
    end

    def apply_defaults
      defaults = @game_data["defaults"]
      return unless defaults

      paper_code = defaults["paper"].to_i
      ink = ColorUtils.spectrum_color_name(defaults["ink"], contrast_against: paper_code)
      paper = ColorUtils.spectrum_color_name(paper_code)
      bright = defaults["bright"].to_i != 0

      @interface.set_colors(ink: ink, paper: paper, bright: bright)
      @interface.set_charset(defaults["charset"].to_i) if defaults.key?("charset")
    end

    def running?
      @running
    end

    def log(msg, level = 1)
      return unless level <= @verbosity
      @runner.ensure_condact_logged if @runner
      @interface.output_debug(msg, level)
    end

    def flag_name(n)
      @flag_descriptions[n] || ProcessRunner::SYSTEM_FLAGS[n]
    end

    def load_flag_descriptions(path)
      return {} unless path && File.exist?(path)

      descriptions = {}
      File.readlines(path).each do |line|
        # Match: "<id> <description>" pairs, e.g. "63 Ammunition".
        if line =~ /^\s*(\d+)\s+(.+)$/
          descriptions[$1.to_i] = $2.strip
        end
      end
      descriptions
    end

    def run
      @running = true
      main_loop while @running
    end

    def restart
      log("🔄 Restarting game...", 1)
      @running = true
      @state.reset!
      @first_turn = true
      self.describe_flag = true
      self.done_flag = false
      @restart_requested = true
    end

    def consume_restart_request
      requested = @restart_requested
      @restart_requested = false
      requested
    end

    def breakpoint_reached(p, b, c, reason: nil)
      @debugger.breakpoint_reached(p, b, c, reason: reason)
    end

    def dump_engine_info
      @debugger.dump_engine_info
    end

    def dump_stack
      @debugger.dump_stack
    end

    def dump_breakpoints
      @debugger.dump_breakpoints
    end

    def dump_current_process(pid, b_idx, c_idx)
      @debugger.dump_current_process(pid, b_idx, c_idx)
    end

    def dump_locations(id_arg = nil)
      @debugger.dump_locations(id_arg)
    end

    def dump_messages(id_arg = nil)
      @debugger.dump_messages(id_arg)
    end

    def dump_system_messages(id_arg = nil)
      @debugger.dump_system_messages(id_arg)
    end

    def dump_objects(id_arg = nil)
      @debugger.dump_objects(id_arg)
    end

    def dump_vocabulary(id_arg = nil)
      @debugger.dump_vocabulary(id_arg)
    end

    def connections_for(loc_id)
      @state.connections[loc_id] || {}
    end

    def dump_connections(loc_id)
      @debugger.dump_connections(loc_id)
    end

    def check_pending_breakpoint
      return unless @pending_breakpoint

      bp = @pending_breakpoint
      @pending_breakpoint = nil
      breakpoint_reached(bp[:p], bp[:b], bp[:c], reason: bp[:reason])
    end

    def dump_state
      @debugger.dump_state
    end

    # --- Main flow ---
    # Following the PAWS cycle (Flowchart 1):
    # 1. Description (if describe_flag is active)
    # 2. Automatic events (Process 2)
    # 3. Player input
    # 4. Response (Process 0 + movement)

    def main_loop
      @turn_loop.call
    end

    def description_phase
      @description_phase.call
    end

    def input_phase
      @input_phase.call
    end

    def log_parser_result
      result = (@current_verb || @current_noun) ? :found : :not_found
      verb_name = vocabulary_word(@current_verb, 0)
      noun_name = vocabulary_word(@current_noun, 2)
      log("🔍 Parser result: #{@interface.fmt_id(result)} (Verb: #{@interface.fmt_val(@current_verb)} #{verb_name}, Noun: #{@interface.fmt_val(@current_noun)} #{noun_name})", 2)
    end

    def clear_phrases
      @input_phase.clear_phrases
    end

    def response_phase
      @response_phase.call
    end

    # --- Location Description ---
    def describe_location
      @description_phase.describe_location
    end

    def location_text(loc)
      @game_data_repository.location_text(loc) || "Location #{loc}"
    end

    def output_location_text(loc, newline: true)
      text = location_text(loc)
      output_text(text, newline: newline) if text
    end

    def list_objects_at(loc)
      objs = @state.objects_at(loc)
      return if objs.empty?

      # Ensure a newline before the visible-object list prefix.
      output_sysmess(1, newline: true) # SM1: visible object list prefix.
      objs.each do |objno|
        text = object_text(objno)
        output_text("  #{text}", newline: true) if text
      end
    end

    # --- Parser ---
    def parse_input(input, is_nested: false)
      clear_parsed_state
      @quoted_buffer = nil # Default reset.

      return if input.nil? || input.strip.empty?

      # 1. Try AI parsing when enabled.
      if @ai_enabled
        log("🤖 AI interpretation starting...", 2)
        ai_command = nil
        begin
          ai_command = ai_parser.parse(input, context: get_ai_context.merge(is_nested: is_nested))
        rescue StandardError => e
          message = "🤖 AI interpretation failed: #{e.class}: #{e.message}"
          warn("[ai-parser] #{e.class}: #{e.message}\n#{e.backtrace&.first(8)&.join("\n")}") if @verbosity.positive?
          log(message, 1)
        end

        if ai_command && !ai_command.empty?
          log("🤖 AI result: #{ai_command.inspect}", 2)
          apply_parsed_command(ai_command)
          return # AI success.
        elsif ai_command
          log("🤖 AI result was empty; falling back to classic parser", 2)
        end
      end

      command = classic_parser.parse(
        input,
        context: { pronoun_resolver: method(:resolve_pronoun) },
      )
      apply_parsed_command(command) if command
    end

    def classic_parser
      @classic_parser ||= ClassicParser.new(vocabulary_lookup: method(:find_vocabulary))
    end

    def ai_parser
      @ai_parser ||= AIParser.new(logger: ->(message, level) { log(message, level) })
    end

    def apply_parsed_command(command)
      @current_verb = command.verb
      @current_noun = command.noun1
      @current_noun2 = command.noun2
      @current_adject = command.adject1
      @current_adject2 = command.adject2
      @current_adverb = command.adverb
      @current_prep = command.prep
      @quoted_buffer = command.quoted_command

      # Convert direction nouns to verbs when no verb was found (important for "N", "S", etc.).
      convert_direction_noun_to_verb if @current_verb.nil? && @current_noun
    end

    def find_vocabulary(word)
      word = word[0, 5] # PAWS uses only 5 characters.
      entry = @game_data_repository.vocabulary_entry_for_word(word)
      if entry
        log("📖 Vocabulary: #{@interface.fmt_word(word)} -> ID #{@interface.fmt_val(entry["id"])} (Type #{@interface.fmt_val(entry["type_id"])})", 2)
      else
        log("📖 Vocabulary: #{@interface.fmt_word(word)} -> NOT FOUND", 3)
      end
      entry
    end

    def convert_direction_noun_to_verb
      # Nouns with ID < 20 are convertible directions (NUM_CONVERTIBLE_NOUNS).
      if @current_noun && @current_noun < 20
        @current_verb = @current_noun
      end
    end

    def resolve_pronoun(pronoun_id)
      # Use the previously referred object.
      @current_noun = @state.get_flag(GameState::FLAG_REFERRED_OBJECT)
      @current_adject = @state.get_flag(GameState::FLAG_PRONOUN_ADJECT)
      { noun1: @current_noun, adject1: @current_adject }
    end

    def store_parsed_words
      # PAWS Manual: "If the verb is omitted then the LS will assume the previously used verb is required."
      @state.set_flag(GameState::FLAG_VERB, @current_verb) if @current_verb

      # 255 represents '_' (Any/None) in PAWS
      @state.set_flag(GameState::FLAG_NOUN1, @current_noun || 255)
      @state.set_flag(GameState::FLAG_ADJECT1, @current_adject || 255)
      @state.set_flag(GameState::FLAG_ADVERB, @current_adverb || 255)
      @state.set_flag(GameState::FLAG_PREP, @current_prep || 255)
      @state.set_flag(GameState::FLAG_NOUN2, @current_noun2 || 255)
      @state.set_flag(GameState::FLAG_ADJECT2, @current_adject2 || 255)
    end

    def clear_parsed_state
      @current_verb = nil
      @current_noun = nil
      @current_adject = nil
      @current_adverb = nil
      @current_prep = nil
      @current_noun2 = nil
      @current_adject2 = nil
    end

    # --- Direction movement ---
    # According to PAWS Flowchart 1 (Direction Branch).
    def fallback_response
      @movement_fallback.fallback_response
    end

    # Direction movement with a reduced API and no text output.
    # Returns :moved if movement happened, :failed if no connection exists.
    # Used from GameHarness and internal pacing tests (does not emit SM7/SM8).
    def try_direction_movement
      @movement_fallback.try_direction_movement
    end

    # --- Phase Methods (public API for pacing tests) ---

    # description_loop runs the full description phase.
    # It is identical to description_phase and exists for pacing test compatibility.
    def description_loop
      description_phase
    end

    # order_loop runs one complete turn cycle (P2, input, response).
    # Same as the inner body of main_loop without the outer catch :desc_jump.
    def order_loop
      @turn_loop.order_loop
    end

    # --- Process Execution ---
    def run_process(process_id, mode: nil)
      @abort_execution = false
      @runner.run_process(process_id, mode: mode)
    end

    def vocabulary_word(id, type_id)
      return "*" if id == 1
      return "_" if id == 255
      return "*" if id == 0 # 0 acts as a wildcard match-all in entry_matches?

      @game_data_repository.vocabulary_word(id, type_id) || "ID#{id}"
    end

    def vocabulary_words(id, type_id)
      return [vocabulary_word(id, type_id)] if [0, 1, 255].include?(id)

      words = @game_data_repository.vocabulary.select do |entry|
        entry["id"] == id && entry["type_id"] == type_id
      end.map { |entry| entry["word"].to_s.upcase }.reject(&:empty?).uniq

      words.empty? ? [vocabulary_word(id, type_id)] : words
    end

    def on_state_change(type, *args)
      case type
      when :flag
        flag = args[0]
        old_val = args[1]
        new_val = args[2]

        name = flag_name(flag)
        name_str = name ? " (#{name})" : ""
        log("💾 F#{flag}#{name_str} changed to #{new_val} (was #{old_val})", 3)

        is_location_bp = (flag == GameState::FLAG_LOCATION && @breakpoint_manager.check_location?(new_val))
        if is_location_bp || @breakpoint_manager.check_flag?(flag, old_val, new_val)
          p = @runner&.process_stack&.last || 0
          b = @runner&.entry_index_stack&.last || 0
          c = @runner&.condact_index_stack&.last || 0

          if is_location_bp
            reason = "Entered location #{new_val}"
          else
            reason = "Flag #{flag}#{name_str} changed from #{old_val} to #{new_val}"
          end

          if @runner&.executing_condact?
            @pending_breakpoint ||= { p: p, b: b, c: c, reason: reason }
          else
            breakpoint_reached(p, b, c, reason: reason)
          end
        end
      when :object
        objno = args[0]
        new_loc = args[1]
        log("📦 Object #{@interface.fmt_val(objno)} moved to #{new_loc}", 3)

        if @breakpoint_manager.check_object?(objno, nil, new_loc, current_location: @state.location)
          p = @runner&.process_stack&.last || 0
          b = @runner&.entry_index_stack&.last || 0
          c = @runner&.condact_index_stack&.last || 0
          reason = "Object #{objno} moved to #{new_loc}"

          if @runner&.executing_condact?
            @pending_breakpoint ||= { p: p, b: b, c: c, reason: reason }
          else
            breakpoint_reached(p, b, c, reason: reason)
          end
        end
      end
    end

    def stop
      log("⏹️  Engine stopping...", 2) if @running
      @running = false
    end

    # --- Helpers ---
    def set_done
      self.done_flag = true
    end

    def set_notdone
      self.done_flag = false
    end

    def done_flag=(val)
      if val != @done_flag && @verbosity >= 2
        log("⚙️  Engine state change: #{@interface.fmt_id("done_flag")} = #{@interface.fmt_val(val)}", 2)
      end
      @done_flag = val
    end

    def describe_flag=(val)
      if val != @describe_flag && @verbosity >= 2
        log("⚙️  Engine state change: #{@interface.fmt_id("describe_flag")} = #{@interface.fmt_val(val)}", 2)
      end
      @describe_flag = val
    end

    def skip_clear_screen=(val)
      if val != @skip_clear_screen && @verbosity >= 2
        log("⚙️  Engine state change: #{@interface.fmt_id("skip_clear_screen")} = #{@interface.fmt_val(val)}", 2)
      end
      @skip_clear_screen = val
    end

    def request_description
      self.describe_flag = true
    end

    def output_message(id, newline: true)
      text = @game_data_repository.message_text(id)
      output_text(text, newline: newline) if text
    end

    def output_text(text, newline: true)
      return if text.nil? || (text.empty? && !newline)

      @runner.ensure_condact_logged if @runner

      # Replace underscore placeholders with the referred object (Flag 51).
      if text.include?("_")
        objno = @state.get_flag(GameState::FLAG_REFERRED_OBJECT)
        # If there is no referred object (255), remove the placeholder.
        obj_name = (objno == 255) ? "" : object_placeholder_text(objno)
        text = text.gsub("_", obj_name)
      end

      @interface.output_text(text, newline: newline)
      record_history(text)
    end

    def record_history(text)
      @history_buffer << text
      @history_buffer.shift if @history_buffer.size > HISTORY_MAX_SIZE
    end

    # Called from InputPhase when a new player input line arrives.
    # Captures a full state snapshot for time-travel debugging.
    def capture_state_snapshot(raw_input)
      return unless @state_history

      @state_history.push(
        turn: @state.turns,
        location: @state.location,
        input: raw_input,
        snapshot: @state.serialize,
      )
    end

    def get_ai_context
      {
        game_title: @game_data_repository.dig("game_info", "title") || "PAWS Adventure",
        location: location_text(@state.location),
        history: @history_buffer,
        inventory: get_inventory_names,
        visible_objects: get_visible_object_names,
        vocabulary: get_vocabulary_summary,
        response_table: get_process_intent_context(0),
        parse_response_table: get_parse_intent_context(0),
        intent_index: get_full_intent_index,
      }
    end

    # Aggregates every unique VERB + NOUN pair that any process table in the
    # game recognises, deduping across processes and merging the
    # adjective/adverb/second-noun/preposition checks from every block that
    # shares the same pair. Pure wildcard entries (verb=1/255 and noun=1/255
    # simultaneously) are skipped: they are universal fall-throughs rather
    # than concrete commands and would only add noise.
    def get_full_intent_index
      index = {}
      processes = @game_data_repository["processes"]
      return [] unless processes.is_a?(Array)

      processes.each do |process|
        next unless process.is_a?(Hash)

        Array(process["entries"]).each do |entry|
          verb_id = entry["verb"]
          noun_id = entry["noun"]
          next if pure_wildcard_pair?(verb_id, noun_id)

          key = [verb_id, noun_id]
          bucket = (index[key] ||= {
            verb: verb_id,
            noun: noun_id,
            checks: [],
          })
          bucket[:checks].concat(scan_condacts_for_vocab(entry["condacts"]))
        end
      end

      index.values.map do |bucket|
        {
          verb: vocabulary_word(bucket[:verb], 0),
          noun: vocabulary_word(bucket[:noun], 2),
          verb_aliases: vocabulary_words(bucket[:verb], 0),
          noun_aliases: vocabulary_words(bucket[:noun], 2),
          checks: dedupe_checks(bucket[:checks]),
        }
      end
    end

    def pure_wildcard_pair?(verb_id, noun_id)
      [1, 0, 255].include?(verb_id.to_i) && [1, 0, 255].include?(noun_id.to_i)
    end

    def dedupe_checks(checks)
      seen = {}
      Array(checks).each do |check|
        key = [check[:type], check[:id] || check[:word]]
        next if seen[key]

        seen[key] = check
      end
      seen.values
    end

    def get_visible_object_names
      @state.objects.filter_map do |objno|
        next unless @state.object_present?(objno)

        object_text(objno)
      end
    end

    def get_inventory_names
      inv = []
      @state.objects.each do |objno|
        if @state.object_carried?(objno) || @state.object_worn?(objno)
          inv << object_text(objno)
        end
      end
      inv.compact
    end

    def get_vocabulary_summary
      @game_data_repository.vocabulary.map do |v|
        { id: v["id"], word: v["word"], type: v["type_id"] }
      end
    end

    def get_process_intent_context(pid)
      process = @game_data_repository.process(pid)
      return [] unless process

      process["entries"].map do |entry|
        {
          verb: vocabulary_word(entry["verb"], 0),
          noun: vocabulary_word(entry["noun"], 2),
          verb_aliases: vocabulary_words(entry["verb"], 0),
          noun_aliases: vocabulary_words(entry["noun"], 2),
          checks: scan_condacts_for_vocab(entry["condacts"]),
        }
      end
    end

    def get_parse_intent_context(pid)
      process = @game_data_repository.process(pid)
      return [] unless process

      process["entries"].filter_map do |entry|
        parse_process_ids = (entry["condacts"] || []).filter_map do |condact|
          next unless condact["name"].to_s.upcase == "PROCESS"

          target_pid = (condact["params"] || [])[0]
          target_process = @game_data_repository.process(target_pid)
          next unless process_uses_parse?(target_process)

          target_pid
        end
        next if parse_process_ids.empty?

        {
          verb: vocabulary_word(entry["verb"], 0),
          noun: vocabulary_word(entry["noun"], 2),
          verb_aliases: vocabulary_words(entry["verb"], 0),
          noun_aliases: vocabulary_words(entry["noun"], 2),
          processes: parse_process_ids.map do |target_pid|
            {
              id: target_pid,
              entries: get_process_intent_context(target_pid).reject do |parse_entry|
                parse_entry[:verb] == "*" && parse_entry[:noun] == "*"
              end,
            }
          end,
        }
      end
    end

    def process_uses_parse?(process)
      return false unless process

      process["entries"].any? do |entry|
        (entry["condacts"] || []).any? { |condact| condact["name"].to_s.upcase == "PARSE" }
      end
    end

    def scan_condacts_for_vocab(condacts)
      return [] unless condacts
      words = []
      condacts.each do |c|
        name = c["name"].upcase
        params = c["params"] || []
        case name
        when "ADJECT1"
          words << { type: "adjective1", word: vocabulary_word(params[0], 3), aliases: vocabulary_words(params[0], 3), id: params[0] }
        when "ADJECT2"
          words << { type: "adjective2", word: vocabulary_word(params[0], 3), aliases: vocabulary_words(params[0], 3), id: params[0] }
        when "NOUN2"
          words << { type: "noun", word: vocabulary_word(params[0], 2), aliases: vocabulary_words(params[0], 2), id: params[0] }
        when "ADVERB"
          words << { type: "adverb", word: vocabulary_word(params[0], 1), aliases: vocabulary_words(params[0], 1), id: params[0] }
        when "PREP"
          words << { type: "preposition", word: vocabulary_word(params[0], 4), aliases: vocabulary_words(params[0], 4), id: params[0] }
        end
      end
      words.uniq
    end

    def output_sysmess(id, newline: true, placeholder: nil)
      text = @game_data_repository.system_message_text(id)

      if text && placeholder
        text = text.gsub("_", placeholder)
      end

      output_text(text, newline: newline) if text
    end

    def object_text(objno)
      @game_data_repository.object_text(objno)
    end

    def object_label_text(objno)
      text = object_text(objno).to_s.dup
      index = text.index(".")
      text = text[0...index] if index
      text.rstrip
    end

    def object_placeholder_text(objno)
      object_label_text(objno).sub(/\A((?:\{[^}]+\})*)\s+/, "\\1")
    end

    def light_present?
      # Object with a light attribute is present.
      (@game_data_repository["objects"] || []).each_with_index do |obj, i|
        next unless obj["is_light"]
        return true if @state.object_present?(i)
      end
      false
    end

    def autodecrement_flags(range)
      range.each { |f| decrement_flag(f) }
    end

    def decrement_flag(n)
      val = @state.get_flag(n)
      @state.set_flag(n, val - 1) if val > 0
    end

    def get_prompt_text
      prompt_id = @state.get_flag(GameState::FLAG_PROMPT)

      # Manual Page 2: a value of 0 will select one of system messages 2,3,4 or 5
      # in the ratio 30:30:30:10 respectively.
      if prompt_id == 0
        r = rand(100)
        prompt_id = if r < 30 then 2 elsif r < 60 then 3 elsif r < 90 then 4 else 5 end
      end

      text = @game_data_repository.system_message_text(prompt_id)

      if text.nil? || text.strip.empty?
        # Manual: the system prompt is shown as a greater-than sign (>).
        "> "
      else
        text += " " unless text.end_with?(" ")
        text
      end
    end

    def current_verb
      @state.get_flag(GameState::FLAG_VERB)
    end

    def current_noun
      @state.get_flag(GameState::FLAG_NOUN1)
    end

    def debug_enabled?
      @debug_enabled
    end

    def phrase_queue
      @phrase_queue
    end

    def replace_phrase_queue(phrases)
      @phrase_queue = phrases
    end

    public

    def get_data_item(collection_name, id)
      @game_data_repository.item(collection_name, id)
    end
  end
end
