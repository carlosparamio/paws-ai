# frozen_string_literal: true

module PAWS
  # Domain value object for PAWS location references.
  # It centralizes normal locations, special object locations, and the HERE alias
  # so debugger, breakpoints, extractor, and runtime code do not duplicate magic numbers.
  class LocationRef
    NOT_CREATED = 252
    WORN = 253
    CARRIED = 254
    HERE = 255

    # DOALL reuses the upper location range as selectors rather than normal
    # object storage locations. WORN/CARRIED/HERE keep their object-location
    # meaning, while 251 and 252 are only meaningful inside DOALL.
    DOALL_ALL_OBJECTS = 251
    DOALL_PRESENT_OBJECTS = 252
    DOALL_WORN_OBJECTS = WORN
    DOALL_CARRIED_OBJECTS = CARRIED
    DOALL_HERE_OBJECTS = HERE
    OBJECT_LOCATION_NAMES = {
      NOT_CREATED => :not_created,
      WORN => :worn,
      CARRIED => :carried,
    }.freeze

    attr_reader :value

    def self.parse(value)
      return value if value.is_a?(self)

      new(normalize(value))
    end

    def self.object_location_name(value)
      OBJECT_LOCATION_NAMES[normalize(value)]
    rescue ArgumentError, TypeError
      nil
    end

    def self.normalize(value)
      case value
      when Symbol
        normalize(value.to_s)
      when String
        normalize_string(value)
      else
        Integer(value)
      end
    end

    def self.normalize_string(value)
      case value.strip.upcase.tr("-", "_")
      when "HERE", "CURRENT"
        HERE
      when "NOT_CREATED", "NC"
        NOT_CREATED
      when "WORN"
        WORN
      when "CARRIED", "INVENTORY"
        CARRIED
      else
        Integer(value)
      end
    end

    private_class_method :normalize, :normalize_string

    def initialize(value)
      @value = Integer(value)
    end

    def not_created?
      value == NOT_CREATED
    end

    def worn?
      value == WORN
    end

    def carried?
      value == CARRIED
    end

    def here?
      value == HERE
    end

    def special?
      not_created? || worn? || carried? || here?
    end

    def numeric?
      !special?
    end

    def resolve(current_location:)
      here? ? Integer(current_location) : value
    end

    def matches?(location, current_location: nil)
      return location.to_s.upcase == "HERE" if here? && current_location.nil?

      resolve(current_location: current_location || location) == Integer(location)
    rescue ArgumentError, TypeError
      to_s == location.to_s.upcase
    end

    def label
      case value
      when NOT_CREATED then "NOT_CREATED"
      when WORN then "WORN"
      when CARRIED then "CARRIED"
      when HERE then "HERE"
      else "L#{value}"
      end
    end

    def to_s
      here? ? "HERE" : value.to_s
    end

    def inspect
      to_s
    end

    def ==(other)
      other_ref = self.class.parse(other)
      value == other_ref.value
    rescue ArgumentError, TypeError
      false
    end

    alias eql? ==

    def hash
      value.hash
    end
  end
end
