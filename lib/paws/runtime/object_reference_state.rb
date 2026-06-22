# frozen_string_literal: true

require_relative "game_state"

module PAWS
  # Maintains the PAWS referred-object flag bundle.
  # Flag 51 stores the current referred object, while flags 54-57 cache its
  # location, weight, container capability, and wearable capability for condacts.
  class ObjectReferenceState
    def initialize(engine)
      @engine = engine
    end

    def update(objno)
      state.set_flag(GameState::FLAG_REFERRED_OBJECT, objno)

      if unknown_object?(objno)
        clear_cached_flags
      else
        state.set_flag(GameState::FLAG_REFERRED_OBJECT_LOC, state.object_at(objno) || 255)
        state.set_flag(GameState::FLAG_REFERRED_OBJECT_WEIGHT, state.object_weight(objno))
        state.set_flag(GameState::FLAG_REFERRED_OBJECT_IS_CONTAINER, object_attr_flag(objno, 14))
        state.set_flag(GameState::FLAG_REFERRED_OBJECT_IS_WEARABLE, object_attr_flag(objno, 15))
      end
    end

    private

    attr_reader :engine

    def state
      engine.state
    end

    def unknown_object?(objno)
      objno == 255 || objno >= (engine.game_data["objects"]&.length || 0)
    end

    def clear_cached_flags
      state.set_flag(GameState::FLAG_REFERRED_OBJECT_LOC, 255)
      state.set_flag(GameState::FLAG_REFERRED_OBJECT_WEIGHT, 0)
      state.set_flag(GameState::FLAG_REFERRED_OBJECT_IS_CONTAINER, 0)
      state.set_flag(GameState::FLAG_REFERRED_OBJECT_IS_WEARABLE, 0)
    end

    def object_attr_flag(objno, attr)
      state.object_attr?(objno, attr) ? 128 : 0
    end
  end
end
