# frozen_string_literal: true

require_relative "game_state"
require_relative "location_ref"

module PAWS
  # Executes PAWS DOALL loops over object sets.
  # DOALL is special because it temporarily rewrites parser flags for each
  # candidate object, updates the referred-object cache, and then continues the
  # remaining condacts or re-enters process 0 depending on response context.
  #
  # Extracting it keeps ProcessRunner from mixing normal sequential condact
  # execution with the object-iteration semantics specific to PAWS. It uses
  # ProcessControl as a small public port back into the runner instead of poking
  # runner stacks directly.
  class DoAllExecutor
    def initialize(engine:, execution_context:, object_reference:, process_control:)
      @engine = engine
      @execution_context = execution_context
      @object_reference = object_reference
      @process_control = process_control
    end

    def call(loc, remaining_condacts)
      object_list = objects_for(loc)
      return :ok if object_list.empty?

      except_noun = engine.state.get_flag(GameState::FLAG_NOUN2)
      in_response = process_control.response_process?
      processed_any = false
      execution_context.reset_doall_abort

      object_list.uniq.each do |objno|
        break if execution_context.abort_doall?
        next if engine.state.object_attr?(objno, 10)

        obj_data = engine.game_data.dig("objects", objno)
        noun_id = obj_data ? obj_data["noun_id"] : 255
        adject_id = obj_data ? obj_data["adjective_id"] : 255
        next if except_noun != 0 && except_noun != 255 && noun_id == except_noun

        engine.state.set_flag(GameState::FLAG_NOUN1, noun_id)
        engine.state.set_flag(GameState::FLAG_ADJECT1, adject_id)
        object_reference.update(objno)

        run_body(remaining_condacts, in_response)
        processed_any = true

        execution_context.mark_notdone
        engine.set_notdone if in_response && !engine.describe_flag
        break if engine.describe_flag
      end

      if processed_any && in_response && !engine.describe_flag
        execution_context.mark_done
        engine.set_done
      end

      :ok
    end

    private

    attr_reader :engine, :execution_context, :object_reference, :process_control

    def objects_for(loc)
      case loc
      when LocationRef::DOALL_ALL_OBJECTS
        (0...engine.state.object_locations.length).to_a
      when LocationRef::DOALL_PRESENT_OBJECTS
        engine.state.objects_at(engine.state.location) + engine.state.carried_objects + engine.state.worn_objects
      when LocationRef::DOALL_WORN_OBJECTS
        engine.state.worn_objects
      when LocationRef::DOALL_CARRIED_OBJECTS
        engine.state.carried_objects
      when LocationRef::DOALL_HERE_OBJECTS
        engine.state.objects_at(engine.state.location)
      else engine.state.objects_at(loc)
      end
    end

    def run_body(remaining_condacts, in_response)
      if remaining_condacts && !remaining_condacts.empty?
        process_control.run_condacts(remaining_condacts)
      elsif in_response
        process_control.run_process(0)
      end
    end
  end
end
