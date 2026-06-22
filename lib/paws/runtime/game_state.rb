# frozen_string_literal: true

require_relative "state/flag_store"
require_relative "state/connection_table"
require_relative "state/object_store"

module PAWS
  # Owns mutable PAWS runtime state: flags, object locations, attributes, connections, and RAMSAVE data.
  # It intentionally avoids rendering, parsing, and process execution so save/load and tests can use it directly.
  # Internally it delegates table-specific behavior to stores for PAWS flag
  # wrapping, object movement/attributes, change notification, and partial
  # RAMLOAD restoration.
  class GameState
    # Special object locations.
    LOC_NOT_CREATED = 252
    LOC_WORN = 253
    LOC_CARRIED = 254

    # System flags.
    FLAG_DARK = 0
    FLAG_OBJECTS_CARRIED = 1
    FLAG_AUTODEC_2 = 2
    FLAG_AUTODEC_3 = 3
    FLAG_AUTODEC_4 = 4
    FLAG_AUTODEC_5 = 5
    FLAG_AUTODEC_6 = 6
    FLAG_AUTODEC_7 = 7
    FLAG_AUTODEC_8 = 8
    FLAG_AUTODEC_9 = 9
    FLAG_AUTODEC_10 = 10
    FLAG_TURNS_LO = 31
    FLAG_TURNS_HI = 32
    FLAG_VERB = 33
    FLAG_NOUN1 = 34
    FLAG_ADJECT1 = 35
    FLAG_ADVERB = 36
    FLAG_MAX_CARRIED = 37
    FLAG_LOCATION = 38
    FLAG_SCREEN_MODE = 40
    FLAG_PROMPT = 42
    FLAG_PREP = 43
    FLAG_NOUN2 = 44
    FLAG_ADJECT2 = 45
    FLAG_PRONOUN = 46
    FLAG_PRONOUN_ADJECT = 47
    FLAG_TIMEOUT_LENGTH = 48
    FLAG_TIMEOUT_FLAGS = 49
    FLAG_DOALL_INDEX = 50
    FLAG_REFERRED_OBJECT = 51
    FLAG_MAX_WEIGHT = 52
    FLAG_LISTING_CONTROL = 53
    FLAG_REFERRED_OBJECT_LOC = 54
    FLAG_REFERRED_OBJECT_WEIGHT = 55
    FLAG_REFERRED_OBJECT_IS_CONTAINER = 56
    FLAG_REFERRED_OBJECT_IS_WEARABLE = 57

    attr_reader :ramsave_slot
    attr_accessor :on_change

    def initialize(game_data, on_change: nil)
      @game_data = game_data
      @on_change = on_change
      reset!
    end

    def reset!
      @flag_store = FlagStore.new(on_change: flag_change_callback)
      init_objects
      init_connections
      init_default_flags
      @ramsave_slot = nil
    end

    # --- Flag accessors ---
    def flags
      @flag_store.values
    end

    def get_flag(n)
      @flag_store.get(n)
    end

    def set_flag(n, value)
      @flag_store.set(n, value)
    end

    def object_locations
      @object_store.locations
    end

    def object_attrs_lo
      @object_store.attrs_lo
    end

    def object_attrs_hi
      @object_store.attrs_hi
    end

    def connections
      @connection_table.values
    end

    def location
      get_flag(FLAG_LOCATION)
    end

    def location=(loc)
      set_flag(FLAG_LOCATION, loc)
    end

    def dark?
      # Manual Page 23: it is dark when flag 0 is > 0 and object 0, the light source, is not present.
      return false if get_flag(FLAG_DARK) == 0
      !object_present?(0)
    end

    def turns
      get_flag(FLAG_TURNS_LO) + (get_flag(FLAG_TURNS_HI) << 8)
    end

    def turns=(val)
      set_flag(FLAG_TURNS_LO, val & 0xFF)
      set_flag(FLAG_TURNS_HI, (val >> 8) & 0xFF)
    end

    def increment_turns
      t = turns + 1
      set_flag(FLAG_TURNS_LO, t & 0xFF)
      set_flag(FLAG_TURNS_HI, (t >> 8) & 0xFF)
    end

    # --- Object accessors ---
    def object_at(objno)
      @object_store.at(objno)
    end

    def set_object_location(objno, loc)
      old_loc, = @object_store.move(objno, loc)

      # Update the carried-object counter.
      if old_loc == LOC_CARRIED && loc != LOC_CARRIED
        set_flag(FLAG_OBJECTS_CARRIED, [get_flag(FLAG_OBJECTS_CARRIED) - 1, 0].max)
      elsif old_loc != LOC_CARRIED && loc == LOC_CARRIED
        set_flag(FLAG_OBJECTS_CARRIED, get_flag(FLAG_OBJECTS_CARRIED) + 1)
      end
    end

    def object_carried?(objno)
      @object_store.carried?(objno, carried_location: LOC_CARRIED)
    end

    def object_worn?(objno)
      @object_store.worn?(objno, worn_location: LOC_WORN)
    end

    def object_here?(objno)
      @object_store.here?(objno, current_location: location)
    end

    def object_present?(objno)
      @object_store.present?(
        objno,
        current_location: location,
        carried_location: LOC_CARRIED,
        worn_location: LOC_WORN,
      )
    end

    def object_absent?(objno)
      !object_present?(objno)
    end

    def objects
      @object_store.objects
    end

    def objects_at(loc)
      @object_store.at_location(loc)
    end

    def listable_objects_at(loc)
      @object_store.listable_at(loc)
    end

    def carried_objects
      objects_at(LOC_CARRIED)
    end

    def worn_objects
      objects_at(LOC_WORN)
    end

    def object_weight(objno)
      @object_store.weight(objno)
    end

    def total_carried_weight
      @object_store.total_weight(carried_objects + worn_objects)
    end

    def object_attr?(objno, attr_bit)
      @object_store.attr?(objno, attr_bit)
    end

    def set_object_attr(objno, attr_bit, value)
      @object_store.set_attr(objno, attr_bit, value)
    end

    # --- Connection accessors ---
    def connection(loc, direction)
      @connection_table.get(loc, direction)
    end

    def set_connection(loc, direction, dest)
      @connection_table.set(loc, direction, dest)
    end

    # --- Serialization for RAMSAVE/RAMLOAD ---
    def ramsave
      @ram_buffer = serialize
    end

    def ramload(flag_limit = 255)
      return false unless @ram_buffer
      deserialize(@ram_buffer, flag_limit: flag_limit)
      true
    end

    def serialize
      {
        flags: @flag_store.values.dup,
        object_locations: object_locations.dup,
        object_attrs_lo: object_attrs_lo.dup,
        object_attrs_hi: object_attrs_hi.dup,
        connections: deep_dup(connections),
      }
    end

    def deserialize(data, flag_limit: 255)
      # PAWS RAMLOAD: "parameter specifies the last flag to be reloaded"
      # Reload only up to flag_limit. Higher flags are preserved.
      @flag_store.reload_until(data[:flags], flag_limit: flag_limit)

      @object_store.replace(
        locations: data[:object_locations],
        attrs_lo: data[:object_attrs_lo],
        attrs_hi: data[:object_attrs_hi],
      )
      @connection_table.replace(data[:connections])
    end

    # Disk save/load.
    def to_json(*args)
      serialize.to_json(*args)
    end

    def self.from_json(json_str, game_data)
      state = new(game_data)
      data = JSON.parse(json_str, symbolize_names: true)
      state.deserialize(data)
      state
    end

    private

    def flag_change_callback
      ->(flag, old_value, new_value) { @on_change&.call(:flag, flag, old_value, new_value) }
    end

    def object_change_callback
      ->(object, location) { @on_change&.call(:object, object, location) }
    end

    def init_objects
      @object_store = ObjectStore.new(
        @game_data,
        not_created_location: LOC_NOT_CREATED,
        on_change: object_change_callback,
      )

      # Count initially carried objects.
      carried = object_locations.count { |location| location == LOC_CARRIED }
      set_flag(FLAG_OBJECTS_CARRIED, carried)
    end

    def init_connections
      @connection_table = ConnectionTable.new(@game_data)
    end

    def init_default_flags
      # Manual default values.
      set_flag(FLAG_MAX_CARRIED, @game_data.dig("defaults", "max_carried") || 4)
      set_flag(FLAG_MAX_WEIGHT, @game_data.dig("defaults", "max_weight") || 10)
      set_flag(FLAG_LOCATION, 0) # Start at location 0 (title).

      # Manual Page 25: Flags 46 & 47 (pronouns) set to 255 (no pronoun)
      set_flag(FLAG_PRONOUN, 255)
      set_flag(FLAG_PRONOUN_ADJECT, 255)

      # Flag 42 = 0 for random prompts by default.
      set_flag(FLAG_PROMPT, 0)

      # Initialize verb/noun as wildcards (*=1) so process 1 matches at startup.
      set_flag(FLAG_VERB, 1)
      set_flag(FLAG_NOUN1, 1)
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.transform_values { |v| deep_dup(v) }
      when Array
        obj.map { |v| deep_dup(v) }
      else
        obj
      end
    end
  end
end
