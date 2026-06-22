# frozen_string_literal: true

require_relative "../../runtime/game_state"
require_relative "../../runtime/execution_result"

module PAWS
  module CondactHandlers
    # Registers condacts that resolve or update the current referred object.
    # ObjectReferenceState owns the canonical referred-object flag bundle.
    module ObjectReference
      module_function

      def register(registry, engine, object_reference:)
        registry.register("WHATO", opcode: 100) do
          whato(engine, object_reference)
        end

        registry.register("PUTO", opcode: 102) do |loc|
          objno = engine.state.get_flag(GameState::FLAG_REFERRED_OBJECT)
          engine.state.set_object_location(objno, loc)
          object_reference.update(objno)
          ExecutionResult.ok("object #{objno} moved to #{loc}")
        end

        registry.register("WEIGH", opcode: 89) do |objno, flag|
          object_reference.update(objno)
          engine.state.set_flag(flag, engine.state.object_weight(objno))
          :ok
        end
      end

      def whato(engine, object_reference)
        noun = engine.state.get_flag(GameState::FLAG_NOUN1)
        adject = engine.state.get_flag(GameState::FLAG_ADJECT1)

        if noun == 0 || noun == 255
          engine.state.set_flag(GameState::FLAG_REFERRED_OBJECT, 255)
          return :ok
        end

        matching_objects = matching_objects_for(engine, noun, adject)
        current_ref = engine.state.get_flag(GameState::FLAG_REFERRED_OBJECT)

        if matching_objects.include?(current_ref)
          object_reference.update(current_ref)
        elsif (present_match = matching_objects.find { |objno| engine.state.object_present?(objno) })
          object_reference.update(present_match)
        elsif matching_objects.any?
          object_reference.update(matching_objects.first)
        else
          object_reference.update(255)
        end

        :ok
      end

      def matching_objects_for(engine, noun, adject)
        matching_objects = []
        engine.game_data["objects"]&.each_with_index do |obj, idx|
          if obj["noun_id"] == noun && (adject == 255 || obj["adjective_id"] == adject)
            matching_objects << idx
          end
        end
        matching_objects
      end
    end
  end
end
