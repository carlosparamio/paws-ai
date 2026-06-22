# frozen_string_literal: true

module PAWS
  # Encapsulates the 256-byte PAWS flag table.
  #
  # This is an internal store used by GameState to keep flag wrapping,
  # partial RAMLOAD restore semantics, and change notification in one place.
  # GameState still exposes its historical flag API, so callers do not need to
  # know that the backing array is managed by this small repository-like object.
  class FlagStore
    SIZE = 256

    attr_reader :values

    def initialize(values = nil, on_change: nil)
      @values = values ? values.dup : Array.new(SIZE, 0)
      @on_change = on_change
    end

    def get(flag)
      @values[flag] || 0
    end

    def set(flag, value)
      new_value = value & 0xFF
      old_value = @values[flag]

      if old_value != new_value
        @values[flag] = new_value
        @on_change&.call(flag, old_value, new_value)
      end

      new_value
    end

    def replace(values)
      @values = values.dup
    end

    def reload_until(values, flag_limit:)
      values.each_with_index do |value, index|
        next if index > flag_limit

        @values[index] = value
      end
    end
  end
end
