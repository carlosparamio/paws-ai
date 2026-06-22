# frozen_string_literal: true

module PAWS
  # Encapsulates PAWS object locations, attributes, and object metadata lookups.
  #
  # GameState owns the broader runtime state, while this store acts as the
  # focused repository for object table behavior: movement, inventory queries,
  # visibility checks, attribute bits, and weight calculation.
  class ObjectStore
    attr_reader :locations, :attrs_lo, :attrs_hi

    def initialize(game_data, not_created_location:, on_change: nil)
      @game_data = game_data
      @not_created_location = not_created_location
      @on_change = on_change
      reset!
    end

    def reset!
      objects = @game_data["objects"] || []
      @locations = objects.map { |object| initial_location(object) }
      @attrs_lo = objects.map { |object| low_attributes(object) }
      @attrs_hi = objects.map { |object| object["attrs_hi"] || 0 }
    end

    def at(object)
      @locations[object]
    end

    def move(object, location)
      old_location = @locations[object]
      @locations[object] = location
      @on_change&.call(object, location) if old_location != location

      [old_location, location]
    end

    def carried?(object, carried_location:)
      at(object) == carried_location
    end

    def worn?(object, worn_location:)
      at(object) == worn_location
    end

    def here?(object, current_location:)
      at(object) == current_location
    end

    def present?(object, current_location:, carried_location:, worn_location:)
      location = at(object)
      location == carried_location || location == worn_location || location == current_location
    end

    def objects
      0...@locations.size
    end

    def at_location(location)
      @locations.each_with_index.select { |object_location, _| object_location == location }.map(&:last)
    end

    def listable_at(location)
      at_location(location).reject { |object| attr?(object, 10) }
    end

    def weight(object)
      @game_data.dig("objects", object, "weight") || 1
    end

    def total_weight(objects)
      objects.sum { |object| weight(object) }
    end

    def attr?(object, attr_bit)
      if attr_bit < 32
        (@attrs_lo[object] & (1 << attr_bit)) != 0
      else
        (@attrs_hi[object] & (1 << (attr_bit - 32))) != 0
      end
    end

    def set_attr(object, attr_bit, value)
      if attr_bit < 32
        set_low_attr(object, attr_bit, value)
      else
        set_high_attr(object, attr_bit - 32, value)
      end
    end

    def replace(locations:, attrs_lo:, attrs_hi:)
      @locations = locations.dup
      @attrs_lo = attrs_lo.dup
      @attrs_hi = attrs_hi.dup
    end

    private

    def initial_location(object)
      object["initial_location"] || object["initially_at"] || @not_created_location
    end

    def low_attributes(object)
      attrs = object["attrs_lo"] || 0
      attrs |= (1 << 14) if object["is_container"]
      attrs |= (1 << 15) if object["is_wearable"]
      attrs
    end

    def set_low_attr(object, bit, value)
      if value
        @attrs_lo[object] |= (1 << bit)
      else
        @attrs_lo[object] &= ~(1 << bit)
      end
    end

    def set_high_attr(object, bit, value)
      if value
        @attrs_hi[object] |= (1 << bit)
      else
        @attrs_hi[object] &= ~(1 << bit)
      end
    end
  end
end
