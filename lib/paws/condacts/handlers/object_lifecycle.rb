# frozen_string_literal: true

require_relative "../../runtime/game_state"

module PAWS
  module CondactHandlers
    # Registers object lifecycle and location mutation condacts.
    # Inventory validation and player-facing failure messages are handled by ObjectInventory.
    module ObjectLifecycle
      module_function

      def register(registry, engine, object_reference:)
        registry.register("CREATE", opcode: 44) do |objno|
          object_reference.update(objno)
          engine.state.set_object_location(objno, engine.state.location)
          :ok
        end

        registry.register("DESTROY", opcode: 43) do |objno|
          object_reference.update(objno)
          engine.state.set_object_location(objno, GameState::LOC_NOT_CREATED)
          :ok
        end

        registry.register("SWAP", opcode: 45) do |obj1, obj2|
          loc1 = engine.state.object_at(obj1)
          loc2 = engine.state.object_at(obj2)

          engine.state.set_object_location(obj1, loc2)
          engine.state.set_object_location(obj2, loc1)
          object_reference.update(obj2)
          :ok
        end

        registry.register("PLACE", opcode: 46) do |objno, locno|
          object_reference.update(objno)
          engine.state.set_object_location(objno, locno)
          :ok
        end

        registry.register("RESET", opcode: 101) do |locno|
          reset(engine, locno)
          registry.call("DESC")
        end
      end

      def reset(engine, locno)
        engine.state.objects.each do |objno|
          if engine.state.object_carried?(objno)
            engine.state.set_object_location(objno, locno)
          else
            start_loc = engine.get_data_item("objects", objno)&.dig("location") || 0
            engine.state.set_object_location(objno, start_loc)
          end
        end

        engine.state.location = locno
      end
    end
  end
end
