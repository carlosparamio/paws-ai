# frozen_string_literal: true

require_relative "../runtime/game_state"

module PAWS
  # Presents debugger read models for flags, processes, vocabulary, objects, and
  # connections. This is a Presenter: it formats existing runtime state for the
  # interactive console but does not mutate the engine. Debugger keeps delegating
  # these methods publicly so external callers have the same API while the bulky
  # rendering code lives in one read-only collaborator.
  class DebugDumps
    def initialize(engine, interface: nil)
      @engine = engine
      @interface = interface || engine.interface
      @state = engine.state
      @game_data = engine.game_data
      @repository = engine.game_data_repository
      @breakpoint_manager = engine.breakpoint_manager
    end

    def dump_flag(number)
      value = @state.get_flag(number)
      name = @engine.flag_name(number)
      @interface.output_text("  F#{number.to_s.ljust(3)} = #{value.to_s.rjust(3)}#{name ? " (#{name})" : ""}")
    end

    def dump_state
      @interface.output_text("\n💾 --- ALL FLAGS ---")
      dump_flags_range(0..255, mode: :auto)
      @interface.output_text("---------------------\n")
    end

    def dump_system_flags
      @interface.output_text("\n⚙️  --- SYSTEM FLAGS (0-59) ---")
      dump_flags_range(0..59, mode: :auto)
      @interface.output_text("-------------------------------\n")
    end

    def dump_user_flags
      @interface.output_text("\n👤 --- ALL USER FLAGS (60-255) ---")
      dump_flags_range(60..255, mode: :all)
      @interface.output_text("----------------------------------\n")
    end

    def dump_known_user_flags
      @interface.output_text("\n👤 --- NAMED USER FLAGS (60-255) ---")
      dump_flags_range(60..255, mode: :known)
      @interface.output_text("------------------------------------\n")
    end

    def dump_engine_info
      @interface.output_text("\n⚙️  --- ENGINE INFO ---")
      @interface.output_text("  Location:    #{@state.location} (#{@engine.location_text(@state.location)})")

      verb = @state.get_flag(GameState::FLAG_VERB)
      verb_name = @engine.vocabulary_word(verb, 0)
      @interface.output_text("  Verb:        #{@interface.fmt_val(verb)} (#{verb_name.empty? ? "NONE" : verb_name})")

      noun1 = @state.get_flag(GameState::FLAG_NOUN1)
      noun1_name = @engine.vocabulary_word(noun1, 2)
      @interface.output_text("  Noun 1:      #{@interface.fmt_val(noun1)} (#{noun1_name.empty? ? "NONE" : noun1_name})")

      noun2 = @state.get_flag(GameState::FLAG_NOUN2)
      noun2_name = @engine.vocabulary_word(noun2, 2)
      @interface.output_text("  Noun 2:      #{@interface.fmt_val(noun2)} (#{noun2_name.empty? ? "NONE" : noun2_name})")

      referred_object = @state.get_flag(GameState::FLAG_REFERRED_OBJECT)
      @interface.output_text("  Referred Obj:#{@interface.fmt_val(referred_object)} (#{@engine.object_text(referred_object) || "None"})")
      @interface.output_text("  Breakpoints: #{breakpoint_count} active")
      @interface.output_text("-----------------------\n")
    end

    def dump_stack
      @interface.output_text("\n🥞 --- STACK TRACE ---")
      stack = @engine.runner.process_stack
      stack.each_with_index do |process, index|
        block_index = @engine.runner.entry_index_stack[index]
        condact_index = @engine.runner.condact_index_stack[index]
        cursor = (index == stack.size - 1) ? "▶ " : "  "
        @interface.output_text("#{cursor}#{index}: P#{process.to_s.rjust(2, "0")} B#{block_index} C#{condact_index.to_s.rjust(2, "0")}")
      end
      @interface.output_text("----------------------\n")
    end

    def dump_current_process(process_id, block_index, condact_index)
      process = find_process(process_id)

      unless process
        @interface.output_text("Process #{process_id} not found")
        return
      end

      entries = process["entries"] || []
      if entries.empty?
        @interface.output_text("Process #{process_id} has no entries")
        return
      end

      target_block = (block_index == 0) ? 1 : block_index
      if target_block < 1 || target_block > entries.size
        @interface.output_text("Block #{target_block} not found in Process #{process_id}")
        return
      end

      output_process_header(process_id, target_block, entries.size)
      output_process_entry(entries[target_block - 1], target_block, condact_index)
      @interface.output_text(@interface.colorize("-" * 40, :cyan))
    end

    def dump_breakpoints
      @interface.output_text("\n🛑 --- ACTIVE BREAKPOINTS ---")
      index = 0
      @breakpoint_manager.breakpoints.each do |type, list|
        list.each do |spec|
          @interface.output_text("  #{index.to_s.rjust(2)}: [#{type.to_s.upcase}] #{spec}")
          index += 1
        end
      end
      @interface.output_text("-----------------------------\n")
    end

    def dump_locations(id)
      @interface.output_text("\n📍 --- LOCATIONS ---")
      locations = @repository["locations"] || []
      if id
        id = id.to_i
        desc = @repository.location_text(id)
        @interface.output_text("  L#{id}: #{desc || "(Empty)"}")
      else
        locations.each_with_index do |location, index|
          desc = location.is_a?(Hash) ? location["description"] : location
          summary = desc.to_s.gsub(/\s+/, " ").strip[0..50]
          @interface.output_text("  L#{index.to_s.ljust(3)}: #{summary}...") if desc
        end
      end
      @interface.output_text("-------------------\n")
    end

    def dump_messages(id)
      @interface.output_text("\n💬 --- MESSAGES ---")
      messages = @repository["messages"] || []
      if id
        id = id.to_i
        message = @repository.message_text(id)
        @interface.output_text("  M#{id}: #{message || "(Empty)"}")
      else
        messages.each_with_index do |message, index|
          summary = message.to_s.gsub(/\s+/, " ").strip[0..50]
          @interface.output_text("  M#{index.to_s.ljust(3)}: #{summary}...") if message && !message.empty?
        end
      end
      @interface.output_text("------------------\n")
    end

    def dump_system_messages(id)
      @interface.output_text("\n🖥️  --- SYSTEM MESSAGES ---")
      messages = @repository["system_messages"] || []
      if id
        id = id.to_i
        message = @repository.system_message_text(id)
        @interface.output_text("  SM#{id}: #{message || "(Empty)"}")
      else
        messages.each_with_index do |message, index|
          text = message.is_a?(Hash) ? message["text"] : message
          summary = text.to_s.gsub(/\s+/, " ").strip[0..50]
          @interface.output_text("  SM#{index.to_s.ljust(3)}: #{summary}...") if text && !text.empty?
        end
      end
      @interface.output_text("------------------------\n")
    end

    def dump_objects(id)
      @interface.output_text("\n📦 --- OBJECTS ---")
      objects = @repository["objects"] || []
      if id
        dump_single_object(id.to_i)
      else
        objects.each_with_index do |object, index|
          name = object.is_a?(Hash) ? (object["name"] || object["description"]) : object
          location = @state.object_at(index)
          @interface.output_text("  O#{index.to_s.ljust(3)}: #{name.to_s.ljust(20)} [Loc: #{location}]") if name
        end
      end
      @interface.output_text("------------------\n")
    end

    def dump_vocabulary(id)
      @interface.output_text("\n📖 --- VOCABULARY ---")
      vocabulary = @repository.vocabulary
      if id
        dump_vocabulary_id(vocabulary, id.to_i)
      else
        vocabulary.group_by { |entry| entry["id"] }.sort.each do |vocab_id, entries|
          words = entries.map { |entry| entry["word"] }.join(", ")
          @interface.output_text("  ID #{vocab_id.to_s.ljust(3)}: #{words}")
        end
      end
      @interface.output_text("---------------------\n")
    end

    def dump_connections(location_id)
      location_id = location_id.to_i
      @interface.output_text("\n🚪 --- CONNECTIONS FOR L#{location_id} ---")
      connections = @engine.connections_for(location_id)
      if connections.empty?
        @interface.output_text("  None.")
      else
        connections.each do |direction, destination|
          verb_text = @engine.vocabulary_word(direction, 0)
          @interface.output_text("  #{verb_text.to_s.ljust(10)} (#{direction}) -> Location #{destination}")
        end
      end
      @interface.output_text("------------------------------\n")
    end

    private

    def dump_flags_range(range, mode: :auto)
      range.each do |number|
        value = @state.get_flag(number)
        desc = @engine.flag_name(number)

        case mode
        when :auto
          next if value == 0 && desc.nil?
        when :known
          next if desc.nil?
        when :all
          # Show everything.
        end

        desc_text = desc ? " (#{desc})" : ""
        @interface.output_text("  F#{number.to_s.ljust(3)} = #{value.to_s.rjust(3)}#{desc_text}")
      end
    end

    def find_process(process_id)
      @repository.process(process_id)
    end

    def output_process_header(process_id, block_index, entry_count)
      header = " 📑 PROCESS #{process_id.to_s.rjust(3, "0")} | BLOCK #{block_index.to_s.rjust(3, "0")} of #{entry_count.to_s.rjust(3, "0")} "
      @interface.output_text("\n" + @interface.colorize(header, :black, :on_cyan, :bold))
    end

    def output_process_entry(entry, block_index, condact_index)
      prefix = (condact_index == 0) ? @interface.colorize("▶ ", :yellow, :bold) : "  "
      block_text = "B#{block_index.to_s.rjust(3, "0")}"
      verb_text = @engine.vocabulary_word(entry["verb"], 0)
      noun_text = @engine.vocabulary_word(entry["noun"], 2)

      @interface.output_text("#{prefix}#{block_text}: #{verb_text} #{noun_text}")
      output_condacts(entry["condacts"] || [], condact_index)
    end

    def output_condacts(condacts, current_condact)
      condacts.each_with_index do |condact, index|
        condact_number = index + 1
        prefix = condact_number == current_condact ? @interface.colorize("    ▶ ", :yellow, :bold) : "      "
        condact_text = "C#{condact_number.to_s.rjust(3, "0")}"
        name = condact["name"].upcase
        params = condact["params"] || []

        @interface.output_text("#{prefix}#{condact_text}: #{name} #{params.join(", ")}")
      end
    end

    def dump_single_object(id)
      name = @engine.object_text(id)
      location = @state.object_at(id)
      location_name = case location
        when GameState::LOC_CARRIED then "Carried"
        when GameState::LOC_WORN then "Worn"
        when GameState::LOC_NOT_CREATED then "Not created"
        else "Location #{location}"
        end
      @interface.output_text("  O#{id}: #{name || "(None)"} [At: #{location_name}]")
    end

    def dump_vocabulary_id(vocabulary, id)
      matches = vocabulary.select { |entry| entry["id"] == id }
      if matches.any?
        matches.each do |entry|
          type = entry["type"] || "Type #{entry["type_id"]}"
          @interface.output_text("  #{entry["word"].ljust(10)} (ID: #{id}, #{type})")
        end
      else
        @interface.output_text("  ID #{id} not found in vocabulary")
      end
    end

    def breakpoint_count
      @breakpoint_manager.breakpoints[:execution].size +
        @breakpoint_manager.breakpoints[:flags].size +
        @breakpoint_manager.breakpoints[:locations].size
    end
  end
end
