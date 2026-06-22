# frozen_string_literal: true

require_relative "../runtime/location_ref"

module PAWS
  # Stores debugger breakpoints and evaluates whether runtime events should stop execution.
  # It parses breakpoint location references once and compares them against changing GameState values.
  class BreakpointManager
    attr_reader :breakpoints

    def initialize(path = nil)
      @breakpoints = {
        execution: [],
        flags: [],
        locations: [],
        objects: [],
      }
      load_file(path) if path
    end

    def load_file(path)
      return unless File.exist?(path)

      File.readlines(path).each do |line|
        line = line.split("#").first&.strip # Remove comments and whitespace
        next if line.nil? || line.empty?

        parse_line(line)
      end
    end

    def parse_line(line)
      line = line.upcase
      if (spec = parse_execution_spec(line))
        @breakpoints[:execution] << spec
        # L10
      elsif line =~ /^L(\d+)$/
        @breakpoints[:locations] << $1.to_i
        # F8=7, F8>7, F8<7, F8 (any change)
      elsif line =~ /^F(\d+)(?:([=> <])(\d+))?$/
        @breakpoints[:flags] << {
          flag: $1.to_i,
          op: $2.nil? ? "!" : ($2 == " " ? "=" : $2),
          value: $3&.to_i,
        }
        # O1=HERE, O1=5
      elsif line =~ /^O(\d+)=(.+)$/
        @breakpoints[:objects] << {
          object: $1.to_i,
          location: LocationRef.parse($2.strip),
        }
      end
    end

    def parse_execution_spec(spec)
      spec = spec.upcase
      # P1, P1B5, P1B5C8, P1B*, P1B8C*, etc.
      if spec =~ /^P(\d+)(?:B(\d+|\*))?(?:C(\d+|\*))?$/
        p = $1.to_i
        b_raw = $2
        c_raw = $3
        b = (b_raw == "*" ? :any : (b_raw ? b_raw.to_i : :any))
        c = (c_raw == "*" ? :any : (c_raw ? c_raw.to_i : :any))
        { process: p, block: b, condact: c }
      else
        nil
      end
    end

    def check_execution?(p, b, c)
      @breakpoints[:execution].any? do |bp|
        match = (bp[:process] == p)
        match &&= (bp[:block] == :any || bp[:block] == b)
        match &&= (bp[:condact] == :any || bp[:condact] == c)
        match
      end
    end

    def check_flag?(flag, old_val, new_val)
      @breakpoints[:flags].any? do |bp|
        next false unless bp[:flag] == flag

        case bp[:op]
        when "=" then new_val == bp[:value]
        when ">" then new_val > bp[:value]
        when "<" then new_val < bp[:value]
        when "!" then new_val != old_val
        else false
        end
      end
    end

    def check_location?(loc)
      @breakpoints[:locations].include?(loc)
    end

    def check_object?(obj, old_loc, new_loc, current_location: nil)
      @breakpoints[:objects].any? do |bp|
        next false unless bp[:object] == obj

        LocationRef.parse(bp[:location]).matches?(new_loc, current_location: current_location)
      end
    end

    def remove_by_index(index)
      # Execution breakpoints first
      if index < @breakpoints[:execution].size
        @breakpoints[:execution].delete_at(index)
        return true
      end
      index -= @breakpoints[:execution].size

      # Then flags
      if index < @breakpoints[:flags].size
        @breakpoints[:flags].delete_at(index)
        return true
      end
      index -= @breakpoints[:flags].size

      # Then locations
      if index < @breakpoints[:locations].size
        @breakpoints[:locations].delete_at(index)
        return true
      end
      index -= @breakpoints[:locations].size

      # Finally objects
      if index < @breakpoints[:objects].size
        @breakpoints[:objects].delete_at(index)
        return true
      end

      false
    end
  end
end
