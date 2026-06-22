# frozen_string_literal: true

require_relative "../runtime/location_ref"

module PAWS
  # Executes debugger commands that intentionally mutate runtime state.
  # Debugger owns the REPL and command dispatch, while this command object owns
  # the small state-changing operations exposed to a debugging session. Keeping
  # them here makes the write surface explicit and leaves read-only dump code in
  # Debugger until that can be split into its own presenter.
  class DebugStateCommands
    def initialize(engine, interface: nil)
      @engine = engine
      @interface = interface || engine.interface
      @state = engine.state
    end

    def set_flag(number, value)
      @state.set_flag(number, value)
      @interface.output_text("  Flag F#{number} set to #{value}")
    end

    def jump_to_location(number)
      @state.location = number
      @engine.describe_flag = true
      @interface.output_text("  Jumped to Location #{number} (#{@engine.location_text(number)})")
    end

    def move_object(number, location_text)
      target_ref = LocationRef.parse(location_text)
      target_location = target_ref.resolve(current_location: @state.location)

      @state.set_object_location(number, target_location)
      location_name = target_ref.here? ? LocationRef.parse(target_location).label : target_ref.label
      @interface.output_text("  Object #{number} (#{@engine.object_text(number)}) moved to #{location_name}")
    end

    def set_verbosity(level)
      @engine.verbosity = level
      @interface.output_text("  Verbosity level set to #{level}")
    end

    def handle_set(arg)
      if arg =~ /^F?(\d+)=(\d+)$/i
        set_flag(::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i)
      else
        @interface.output_text("Usage: F<n>=<v> (e.g. F8=10)")
      end
    end
  end
end
