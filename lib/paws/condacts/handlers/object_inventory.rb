# frozen_string_literal: true

require_relative "../../runtime/game_state"

module PAWS
  module CondactHandlers
    # Registers inventory and container manipulation condacts.
    # It owns PAWS inventory validation messages while the runner still owns DOALL abort
    # bookkeeping through ProcessExecutionContext.
    module ObjectInventory
      module_function

      def register(registry, engine, object_reference:, execution_context:)
        registry.register("GET", opcode: 40) { |objno| get(engine, object_reference, execution_context, objno) }
        registry.register("DROP", opcode: 41) { |objno| drop(engine, object_reference, execution_context, objno) }
        registry.register("WEAR", opcode: 42) { |objno| wear(engine, object_reference, execution_context, objno) }
        registry.register("REMOVE", opcode: 39) { |objno| remove(engine, object_reference, execution_context, objno) }
        registry.register("PUTIN", opcode: 90) { |objno, locno| putin(engine, object_reference, execution_context, objno, locno) }
        registry.register("TAKEOUT", opcode: 91) { |objno, container_loc| takeout(engine, object_reference, execution_context, objno, container_loc) }
        registry.register("DROPALL", opcode: 30) { dropall(engine) }
      end

      def get(engine, object_reference, execution_context, objno)
        return abort_with_logic(engine, execution_context, 26) if objno == 255

        object_reference.update(objno)
        loc = engine.state.object_at(objno)
        return abort_with_logic(engine, execution_context, 25) if loc == GameState::LOC_CARRIED || loc == GameState::LOC_WORN
        return abort_with_logic(engine, execution_context, 26) if loc != engine.state.location

        obj_weight = engine.state.object_weight(objno)
        max_weight = engine.state.get_flag(GameState::FLAG_MAX_WEIGHT)
        if max_weight > 0 && engine.state.total_carried_weight + obj_weight > max_weight
          return abort_with_logic(engine, execution_context, 43, engine.object_placeholder_text(objno))
        end

        max_carried = engine.state.get_flag(GameState::FLAG_MAX_CARRIED)
        if engine.state.get_flag(GameState::FLAG_OBJECTS_CARRIED) >= max_carried
          execution_context.abort_doall!
          return abort_with_logic(engine, execution_context, 27)
        end

        engine.state.set_object_location(objno, GameState::LOC_CARRIED)
        engine.output_sysmess(36, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def drop(engine, object_reference, execution_context, objno)
        return abort_with_logic(engine, execution_context, 28) if objno == 255

        object_reference.update(objno)
        return abort_with_logic(engine, execution_context, 24) if engine.state.object_worn?(objno)

        unless engine.state.object_carried?(objno)
          return abort_with_logic(engine, execution_context, 49) if engine.state.object_at(objno) == engine.state.location

          return abort_with_logic(engine, execution_context, 28)
        end

        engine.state.set_object_location(objno, engine.state.location)
        engine.output_sysmess(39, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def wear(engine, object_reference, execution_context, objno)
        return abort_with_logic(engine, execution_context, 28) if objno == 255

        object_reference.update(objno)
        return abort_with_logic(engine, execution_context, 29) if engine.state.object_worn?(objno)

        unless engine.state.object_carried?(objno)
          return abort_with_logic(engine, execution_context, 49) if engine.state.object_at(objno) == engine.state.location

          return abort_with_logic(engine, execution_context, 28)
        end

        return abort_with_logic(engine, execution_context, 40) unless engine.state.object_attr?(objno, 15)

        engine.state.set_object_location(objno, GameState::LOC_WORN)
        engine.output_sysmess(37, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def remove(engine, object_reference, execution_context, objno)
        return abort_with_logic(engine, execution_context, 23) if objno == 255

        object_reference.update(objno)
        unless engine.state.object_worn?(objno)
          return abort_with_logic(engine, execution_context, 50) if engine.state.object_carried?(objno) || engine.state.object_at(objno) == engine.state.location

          return abort_with_logic(engine, execution_context, 23)
        end

        return abort_with_logic(engine, execution_context, 41) unless engine.state.object_attr?(objno, 15)

        max_carried = engine.state.get_flag(GameState::FLAG_MAX_CARRIED)
        return abort_with_logic(engine, execution_context, 42) if engine.state.get_flag(GameState::FLAG_OBJECTS_CARRIED) >= max_carried

        engine.state.set_object_location(objno, GameState::LOC_CARRIED)
        engine.output_sysmess(38, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def putin(engine, object_reference, execution_context, objno, locno)
        return abort_with_logic(engine, execution_context, 28) if objno == 255

        object_reference.update(objno)
        if engine.state.object_worn?(objno)
          return abort_with_logic(engine, execution_context, 24)
        elsif engine.state.object_at(objno) == engine.state.location
          return abort_with_logic(engine, execution_context, 49)
        elsif !engine.state.object_carried?(objno)
          return abort_with_logic(engine, execution_context, 28)
        end

        engine.state.set_object_location(objno, locno)
        engine.output_sysmess(44, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def dropall(engine)
        engine.state.carried_objects.each do |objno|
          engine.state.set_object_location(objno, engine.state.location)
        end
        engine.state.set_flag(GameState::FLAG_OBJECTS_CARRIED, 0)
        :ok
      end

      def takeout(engine, object_reference, execution_context, objno, container_loc)
        return abort_with_logic(engine, execution_context, 26) if objno == 255

        object_reference.update(objno)
        return abort_with_logic(engine, execution_context, 25) if engine.state.object_worn?(objno) || engine.state.object_carried?(objno)
        return abort_with_logic(engine, execution_context, 45) if engine.state.object_at(objno) == engine.state.location

        if engine.state.object_at(objno) != container_loc
          return abort_with_logic(engine, execution_context, 52, engine.object_text(engine.state.location))
        end

        obj_weight = engine.state.object_weight(objno)
        max_weight = engine.state.get_flag(GameState::FLAG_MAX_WEIGHT)
        if max_weight > 0 && engine.state.total_carried_weight + obj_weight > max_weight
          return abort_with_logic(engine, execution_context, 43, engine.object_placeholder_text(objno))
        end

        max_carried = engine.state.get_flag(GameState::FLAG_MAX_CARRIED)
        return abort_with_logic(engine, execution_context, 27) if engine.state.get_flag(GameState::FLAG_OBJECTS_CARRIED) >= max_carried

        engine.state.set_object_location(objno, GameState::LOC_CARRIED)
        engine.output_sysmess(36, placeholder: engine.object_placeholder_text(objno))
        :ok
      end

      def abort_with_logic(engine, execution_context, sm_id, placeholder = nil)
        engine.output_sysmess(sm_id, placeholder: placeholder)
        execution_context.mark_done
        engine.set_done
        :failed
      end
    end
  end
end
