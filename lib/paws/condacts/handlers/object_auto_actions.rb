# frozen_string_literal: true

require_relative "../../runtime/game_state"

module PAWS
  module CondactHandlers
    # Registers automatic object actions that resolve the referred object, then delegate
    # to the normal inventory/container action.
    module ObjectAutoActions
      module_function

      def register(registry, engine)
        registry.register("AUTOG", opcode: 31) do
          objno = resolve_object(engine, [engine.state.location, GameState::LOC_CARRIED, GameState::LOC_WORN])
          registry.call("GET", [objno])
        end

        registry.register("AUTOD", opcode: 32) do
          objno = resolve_object(engine, [GameState::LOC_CARRIED, GameState::LOC_WORN, engine.state.location])
          registry.call("DROP", [objno])
        end

        registry.register("AUTOW", opcode: 33) do
          objno = resolve_object(engine, [GameState::LOC_CARRIED, GameState::LOC_WORN, engine.state.location])
          registry.call("WEAR", [objno])
        end

        registry.register("AUTOR", opcode: 34) do
          objno = resolve_object(engine, [GameState::LOC_WORN, GameState::LOC_CARRIED, engine.state.location])
          registry.call("REMOVE", [objno])
        end

        registry.register("AUTOP", opcode: 104) do |container_loc|
          objno = resolve_object(engine, [GameState::LOC_CARRIED, GameState::LOC_WORN, engine.state.location])
          registry.call("PUTIN", [objno, container_loc])
        end

        registry.register("AUTOT", opcode: 105) do |container_loc|
          objno = resolve_object(engine, [container_loc, GameState::LOC_CARRIED, GameState::LOC_WORN, engine.state.location])
          registry.call("TAKEOUT", [objno, container_loc])
        end
      end

      def resolve_object(engine, priority_locations)
        noun = engine.state.get_flag(GameState::FLAG_NOUN1)
        adject = engine.state.get_flag(GameState::FLAG_ADJECT1)
        return 255 if noun == 0 || noun == 255

        matching_objects = matching_objects_for(engine, noun, adject)
        priority_locations.each do |loc|
          match = matching_objects.find { |objno| engine.state.object_at(objno) == loc }
          return match if match
        end

        matching_objects.first || 255
      end

      def matching_objects_for(engine, noun, adject)
        engine.game_data["objects"].each_with_index.filter_map do |obj, idx|
          next unless obj["noun_id"] == noun
          next unless adject == 255 || obj["adjective_id"] == adject

          idx
        end
      end
    end
  end
end
