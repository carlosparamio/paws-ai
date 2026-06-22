# frozen_string_literal: true

module PAWS
  # Circular buffer of GameState snapshots for time-travel debugging.
  #
  # Each entry holds a serialized state hash, a turn number, a wall-clock
  # timestamp, the player's location, and the raw input that was about to be
  # processed. The buffer is fixed-size and silently discards the oldest entry
  # when capacity is reached.
  #
  # StateHistory is a pure data structure with no dependency on Engine or
  # GameState — it stores and retrieves opaque snapshot hashes produced by
  # GameState#serialize.
  class StateHistory
    DEFAULT_CAPACITY = 200

    Entry = Struct.new(:turn, :timestamp, :location, :input, :snapshot, keyword_init: true)

    def initialize(capacity: DEFAULT_CAPACITY)
      @capacity = [capacity, 1].max
      @entries = []
    end

    # Record a new snapshot. If the buffer is full, the oldest entry is dropped.
    def push(turn:, location:, input:, snapshot:)
      @entries.shift if @entries.size >= @capacity
      @entries << Entry.new(
        turn: turn,
        timestamp: Time.now,
        location: location,
        input: input,
        snapshot: snapshot,
      )
    end

    # Return a defensive copy of all entries (oldest first).
    def entries
      @entries.dup
    end

    def size
      @entries.size
    end

    def empty?
      @entries.empty?
    end

    # Access an entry by its buffer index (0 = oldest).
    def [](index)
      @entries[index]
    end

    # Find the entry for an exact turn number.
    def at_turn(turn)
      @entries.find { |e| e.turn == turn }
    end

    # Return the entry N steps before the most recent one.
    # back(0) returns the latest entry, back(1) returns one before that, etc.
    def back(steps = 1)
      return nil if @entries.empty? || steps >= @entries.size
      @entries[-(steps + 1)]
    end

    # The most recent entry.
    def latest
      @entries.last
    end

    def clear
      @entries.clear
    end

    def truncate_after(index)
      return if index < 0 || index >= @entries.size
      @entries = @entries[0..index]
    end

    attr_reader :capacity
  end
end
