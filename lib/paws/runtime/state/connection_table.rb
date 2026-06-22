# frozen_string_literal: true

module PAWS
  # Encapsulates the PAWS location connection table.
  #
  # The extracted game data stores exits as pairs grouped by location. This
  # table normalizes that representation into a nested hash optimized for
  # runtime movement checks while preserving GameState's public connection API.
  class ConnectionTable
    attr_reader :values

    def initialize(game_data)
      @game_data = game_data
      reset!
    end

    def reset!
      @values = {}

      connections.each do |location, directions|
        @values[location] = {}
        directions.each { |direction, destination| @values[location][direction] = destination }
      end
    end

    def get(location, direction)
      @values.dig(location, direction)
    end

    def set(location, direction, destination)
      @values[location] ||= {}
      @values[location][direction] = destination
    end

    def replace(values)
      @values = deep_dup(values)
    end

    private

    def connections
      @game_data["connections"] || @game_data[:connections] || []
    end

    def deep_dup(object)
      case object
      when Hash
        object.transform_values { |value| deep_dup(value) }
      when Array
        object.map { |value| deep_dup(value) }
      else
        object
      end
    end
  end
end
