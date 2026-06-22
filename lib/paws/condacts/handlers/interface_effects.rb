# frozen_string_literal: true

require_relative "../../utils/color_utils"
require_relative "../../runtime/game_state"
require_relative "../../runtime/runtime_capabilities"

module PAWS
  module CondactHandlers
    # Registers condacts that talk to the runtime interface or platform effects.
    # It keeps UI, timing, color, and unsupported display behavior outside the process loop.
    module InterfaceEffects
      module_function

      def register(registry, engine, unsupported:, optional_noop:, sleeper:, bell:, capabilities: RuntimeCapabilities.cli)
        register_text_output(registry, engine)
        register_input_and_timing(registry, engine, sleeper: sleeper)
        register_screen_and_color(registry, engine, unsupported: unsupported, capabilities: capabilities)
        register_platform_effects(
          engine,
          registry,
          unsupported: unsupported,
          optional_noop: optional_noop,
          capabilities: capabilities,
          bell: bell,
        )
      end

      def register_text_output(registry, engine)
        registry.register("MESSAGE", opcode: 38) do |msg|
          output_message(engine, msg, newline: true)
        end

        registry.register("MES", opcode: 77) do |msg|
          output_message(engine, msg, newline: false)
        end

        registry.register("SYSMESS", opcode: 54) do |msg|
          engine.output_sysmess(msg, newline: false)
          :ok
        end

        registry.register("NEWLINE", opcode: 52) do
          engine.output_text("")
          :ok
        end

        registry.register("PRINT", opcode: 53) do |flag|
          engine.output_text(engine.state.get_flag(flag).to_s)
          :ok
        end

        registry.register("PROMPT", opcode: 86) do |msg|
          engine.state.set_flag(GameState::FLAG_PROMPT, msg)
          :ok
        end
      end

      def register_input_and_timing(registry, engine, sleeper:)
        registry.register("ANYKEY", opcode: 24) do
          engine.output_sysmess(16, newline: false)
          engine.interface.wait_for_key
          engine.interface.flush_input_buffer
          :ok
        end

        registry.register("PAUSE", opcode: 35) do |duration|
          actual_duration = duration == 0 ? 256 : duration
          seconds = actual_duration / 50.0
          if engine.interface.respond_to?(:pause)
            engine.interface.pause(seconds)
          else
            sleeper.call(seconds)
          end
          :ok
        end
      end

      def register_screen_and_color(registry, engine, unsupported:, capabilities:)
        registry.register("CLS", opcode: 29) do
          engine.log("CLS condact: skip_clear_screen=#{engine.skip_clear_screen}", 2)
          engine.interface.clear_screen unless engine.skip_clear_screen
          :ok
        end

        registry.register("INK", opcode: 66) do |color|
          set_color(engine, ink: color_name(color))
        end

        registry.register("PAPER", opcode: 65) do |color|
          set_color(engine, paper: color_name(color))
        end

        registry.register("CHARSET", opcode: 78) do |charset|
          engine.interface.set_charset(charset)
          :ok
        end

        registry.register("MODE", opcode: 81) do |mode, _value|
          engine.state.set_flag(GameState::FLAG_SCREEN_MODE, mode)
          :ok
        end

        registry.register("BORDER", opcode: 67) do |color|
          unsupported.call(
            "BORDER",
            [color],
            reason: capabilities.unsupported_reason(:screen_border_color),
          )
        end

        registry.register("LINE", opcode: 82) do |line|
          next :ok if capabilities.screen_graphics? && engine.interface.respond_to?(:set_graphics_line) && engine.interface.set_graphics_line(line)

          unsupported.call(
            "LINE",
            [line],
            reason: capabilities.unsupported_reason(:graphics_line_positioning),
          )
        end

        registry.register("PICTURE", opcode: 84) do |pic|
          next :ok if capabilities.screen_graphics? && engine.interface.show_picture(pic)

          unsupported.call(
            "PICTURE",
            [pic],
            reason: capabilities.unsupported_reason(:picture_loading),
          )
        end

        registry.register("GRAPHIC", opcode: 87) do |mode|
          next :ok if capabilities.screen_graphics?

          unsupported.call(
            "GRAPHIC",
            [mode],
            reason: capabilities.unsupported_reason(:graphics_mode),
          )
        end

        registry.register("PRINTAT", opcode: 99) do |line, col|
          next :ok if capabilities.screen_graphics? && engine.interface.print_at(line, col)

          unsupported.call(
            "PRINTAT",
            [line, col],
            reason: capabilities.unsupported_reason(:cursor_positioning),
          )
        end
      end

      def register_platform_effects(engine, registry, unsupported:, optional_noop:, capabilities:, bell:)
        registry.register("BEEP", opcode: 64) do |duration, pitch|
          optional_noop.call(
            "BEEP",
            [duration, pitch],
            reason: capabilities.optional_noop_reason(:sound),
          )
        end

        registry.register("BELL") do
          bell.call
          :ok
        end

        registry.register("EXTERN", opcode: 61) do |value|
          next :ok if capabilities.screen_graphics? && engine.interface.respond_to?(:show_external) && engine.interface.show_external(value)

          unsupported.call(
            "EXTERN",
            [value],
            reason: capabilities.unsupported_reason(:external_routine_calls),
          )
        end

        registry.register("PROTECT", opcode: 107) do
          optional_noop.call(
            "PROTECT",
            [],
            reason: capabilities.optional_noop_reason(:copy_protection),
          )
        end

        registry.register("COPYFB") do |flag, addr|
          unsupported.call(
            "COPYFB",
            [flag, addr],
            reason: capabilities.unsupported_reason(:direct_memory_access),
          )
        end

        registry.register("COPYBF") do |addr, flag|
          unsupported.call(
            "COPYBF",
            [addr, flag],
            reason: capabilities.unsupported_reason(:direct_memory_access),
          )
        end
      end

      def output_message(engine, msg, newline:)
        engine.output_message(msg, newline: newline)
        :ok
      end

      def set_color(engine, **colors)
        engine.interface.set_colors(**colors)
        :ok
      end

      def color_name(code)
        ColorUtils::COLOR_NAMES[code.to_i & 7] || "white"
      end
    end
  end
end
