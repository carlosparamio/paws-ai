# frozen_string_literal: true

require_relative "../../runtime/game_state"

module PAWS
  module CondactHandlers
    # Registers informational condacts that render inventory, visible objects, turns, and score.
    # The handler owns listing presentation details while ProcessRunner keeps process sequencing.
    module Information
      module_function

      def register(registry, engine)
        registry.register("INVEN", opcode: 18) do
          inventory(engine)
        end

        registry.register("TURNS", opcode: 27) do
          turns(engine)
        end

        registry.register("SCORE", opcode: 28) do
          score(engine)
        end

        registry.register("LISTOBJ", opcode: 60) do
          listobj(engine)
        end

        registry.register("LISTAT", opcode: 74) do |loc|
          listat(engine, loc)
        end
      end

      def inventory(engine)
        objects = engine.state.carried_objects + engine.state.worn_objects

        if objects.empty?
          engine.output_sysmess(9, newline: false)
          engine.output_sysmess(11, newline: true)
        else
          engine.output_sysmess(9, newline: false)
          list_inventory_objects(engine, objects)
        end

        :done
      end

      def listobj(engine)
        objects = engine.state.listable_objects_at(engine.state.location)
        return :ok if objects.empty?

        engine.output_sysmess(1, newline: !continuous_listing?(engine))
        list_objects(engine, objects, empty_terminator_newline: true)
        :done
      end

      def listat(engine, loc)
        objects = engine.state.listable_objects_at(loc)

        if objects.empty?
          engine.output_sysmess(53)
        else
          list_objects(engine, objects, empty_terminator_newline: false)
        end

        :ok
      end

      def turns(engine)
        turns = engine.state.turns

        engine.output_sysmess(17, newline: false)
        engine.output_text(turns.to_s, newline: false)
        engine.output_sysmess(18, newline: false)
        engine.output_sysmess(19, newline: false) unless turns == 1
        engine.output_sysmess(20, newline: true) unless empty_system_message?(engine, 20)

        :ok
      end

      def score(engine)
        score = engine.state.get_flag(30)

        engine.output_sysmess(21, newline: false)
        engine.output_text(score.to_s, newline: false)
        engine.output_sysmess(22, newline: true)

        :ok
      end

      def list_inventory_objects(engine, objects)
        if continuous_listing?(engine)
          list_inventory_continuous(engine, objects)
        else
          list_inventory_vertical(engine, objects)
        end
      end

      def list_inventory_continuous(engine, objects)
        objects.each_with_index do |objno, index|
          output_separator(engine, index, objects.length)
          output_inventory_name(engine, objno)
        end

        output_list_terminator(engine, objects)
      end

      def list_inventory_vertical(engine, objects)
        objects.each do |objno|
          text = "  #{engine.object_text(objno)}"

          if engine.state.object_worn?(objno)
            engine.output_text(text, newline: false)
            engine.output_sysmess(10, newline: true)
          else
            engine.output_text(text, newline: true)
          end
        end
      end

      def list_objects(engine, objects, empty_terminator_newline: true)
        return if objects.empty?

        mark_objects_listed(engine)

        objects.each_with_index do |objno, index|
          if continuous_listing?(engine)
            output_separator(engine, index, objects.length)
            output_listed_object_name(engine, objno)
          else
            engine.output_text(engine.object_text(objno), newline: true)
          end
        end

        output_list_terminator(engine, objects, empty_terminator_newline: empty_terminator_newline) if continuous_listing?(engine)
      end

      def output_separator(engine, index, size)
        return if index.zero?

        if index == size - 1
          engine.output_sysmess(47, newline: false)
        else
          engine.output_sysmess(46, newline: false)
        end
      end

      def output_inventory_name(engine, objno)
        name = listed_object_text(engine, objno)
        downcase_first_character!(name)

        engine.output_text(name, newline: false)
        engine.output_sysmess(10, newline: false) if engine.state.object_worn?(objno)
      end

      def output_listed_object_name(engine, objno)
        name = listed_object_text(engine, objno)
        downcase_first_character!(name)
        engine.output_text(name, newline: false)
      end

      def output_list_terminator(engine, objects, empty_terminator_newline: true)
        if object_text_ends_sentence?(listed_object_text(engine, objects.last))
          engine.output_text("")
        elsif empty_system_message?(engine, 48) && !empty_terminator_newline
          nil
        else
          engine.output_sysmess(48, newline: true)
        end
      end

      def downcase_first_character!(text)
        return if text.nil? || text.empty?

        text.sub!(/\A((?:\{[^}]+\})*)(\p{Lu})/) do
          "#{$1}#{$2.downcase}"
        end
      end

      def listed_object_text(engine, objno)
        engine.object_label_text(objno).to_s.dup
      end

      def object_text_ends_sentence?(text)
        text.to_s.gsub(/\{[^}]+\}/, "").rstrip.end_with?(".", "!", "?")
      end

      def empty_system_message?(engine, id)
        return false unless engine.respond_to?(:game_data_repository)

        repository = engine.game_data_repository
        return false unless repository.respond_to?(:system_message_text)

        repository.system_message_text(id).to_s.empty?
      end

      def mark_objects_listed(engine)
        listing_control = engine.state.get_flag(GameState::FLAG_LISTING_CONTROL)
        engine.state.set_flag(GameState::FLAG_LISTING_CONTROL, listing_control | 0x80)
      end

      def continuous_listing?(engine)
        (engine.state.get_flag(GameState::FLAG_LISTING_CONTROL) & 0x40) != 0
      end
    end
  end
end
