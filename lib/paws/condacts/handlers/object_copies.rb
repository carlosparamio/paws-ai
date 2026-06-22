# frozen_string_literal: true

module PAWS
  module CondactHandlers
    # Registers object/flag copy condacts that move object location values between slots.
    # Referred-object bookkeeping is delegated to ObjectReferenceState.
    module ObjectCopies
      module_function

      def register(registry, engine, object_reference:)
        registry.register("COPYOF", opcode: 56) do |objno, flag|
          engine.state.set_flag(flag, engine.state.object_at(objno))
          :ok
        end

        registry.register("COPYOO", opcode: 57) do |source_obj, target_obj|
          object_reference.update(target_obj)
          engine.state.set_object_location(target_obj, engine.state.object_at(source_obj))
          :ok
        end

        registry.register("COPYFO", opcode: 58) do |flag, objno|
          object_reference.update(objno)
          engine.state.set_object_location(objno, engine.state.get_flag(flag))
          :ok
        end
      end
    end
  end
end
