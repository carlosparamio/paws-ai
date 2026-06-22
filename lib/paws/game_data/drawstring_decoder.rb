# frozen_string_literal: true

module PAWS
  module GameData
    # PAWS drawstring decoder.
    #
    # This preserves the raw command bytes and exposes a semantic command stream
    # shaped by the command lengths observed in the PAW Z80 graphics routine.
    class DrawstringDecoder
      END_MARKER = 0x07

      FAMILY_LENGTHS = {
        0 => 3,
        1 => 3,
        2 => 4,
        3 => 2,
        4 => 4,
        5 => 1,
        6 => 1,
        7 => 1,
      }.freeze

      EFFECT_MASK = 0x18
      PIXEL_NEUTRAL_EFFECT = 0x18

      def decode(raw_bytes)
        bytes = raw_bytes || []
        commands = []
        warnings = []
        offset = 0
        point = { "x" => 0, "y" => 0 }

        while offset < bytes.length
          opcode = bytes[offset]
          remaining = bytes.length - offset
          family = opcode & 0x07
          length = command_length(opcode, remaining)

          if length > remaining
            commands << trailing_command(offset, bytes[offset..])
            warnings << "truncated command at offset #{offset}"
            break
          end

          command = command_for(offset, bytes[offset, length], bytes.length, point)
          warnings << out_of_range_warning(command) if out_of_range?(command)
          commands << command
          point = command["point_after"] if command.key?("point_after")
          offset += length
        end

        {
          "commands" => commands,
          "warnings" => warnings,
          "consumed_bytes" => offset,
        }
      end

      private

      def command_length(opcode, remaining)
        return 1 if opcode == END_MARKER && remaining == 1
        return family_two_length(opcode) if (opcode & 0x07) == 2

        FAMILY_LENGTHS.fetch(opcode & 0x07)
      end

      def family_two_length(opcode)
        return 5 if opcode == 0x12
        return 4 if (opcode & 0x20) != 0

        3
      end

      def command_for(offset, bytes, total_length, point)
        opcode = bytes.fetch(0)
        family = opcode & 0x07
        command = {
          "offset" => offset,
          "opcode" => opcode,
          "family" => family,
          "name" => command_name(opcode, offset, total_length),
          "raw_bytes" => bytes,
          "point_before" => point.dup,
        }

        enrich_command(command)
      end

      def command_name(opcode, offset, total_length)
        return "end_marker" if opcode == END_MARKER && offset == total_length - 1

        case opcode & 0x07
        when 0
          pixel_neutral_effect?(opcode) ? "absolute_move" : "plot"
        when 1
          pixel_neutral_effect?(opcode) ? "relative_move" : "line"
        when 2
          family_two_command_name(opcode)
        when 3
          "gosub"
        when 4
          "draw_character"
        when 5
          (opcode & 0x80) != 0 ? "bright" : "paper"
        when 6
          (opcode & 0x80) != 0 ? "flash" : "ink"
        else
          "control"
        end
      end

      def enrich_command(command)
        case command.fetch("family")
        when 0
          target = absolute_target(command)
          command.merge(
            "x" => target.fetch("x"),
            "y" => target.fetch("y"),
            "point_after" => target,
            "inverse_bit" => inverse_bit?(command.fetch("opcode")),
            "over_bit" => over_bit?(command.fetch("opcode")),
            "pixel_effect" => pixel_effect(command.fetch("opcode")),
          )
        when 1
          delta = signed_relative_delta(command)
          target = relative_target(command.fetch("point_before"), delta)
          command.merge(
            "dx" => delta.fetch("dx"),
            "dy" => delta.fetch("dy"),
            "point_after" => target,
            "negative_dx_bit" => (command.fetch("opcode") & 0x40) != 0,
            "negative_dy_bit" => (command.fetch("opcode") & 0x80) != 0,
            "inverse_bit" => inverse_bit?(command.fetch("opcode")),
            "over_bit" => over_bit?(command.fetch("opcode")),
            "pixel_effect" => pixel_effect(command.fetch("opcode")),
          )
        when 2
          delta = signed_relative_delta(command)
          tip = relative_target(command.fetch("point_before"), delta)
          attribute_block = family_two_attribute_block(command)
          pattern_byte = family_two_pattern_byte(command)
          shade_pattern = family_two_shade_pattern(command)
          command.merge(
            "params" => command.fetch("raw_bytes")[1..],
            "attribute_block" => attribute_block,
            "pattern_byte" => pattern_byte,
            "shade_pattern" => shade_pattern,
            "dx" => delta.fetch("dx"),
            "dy" => delta.fetch("dy"),
            "tip" => tip,
            "inverse_bit" => inverse_bit?(command.fetch("opcode")),
            "over_bit" => over_bit?(command.fetch("opcode")),
            "pixel_effect" => pixel_effect(command.fetch("opcode")),
          )
        when 3
          command.merge(
            "picture_id" => command.fetch("raw_bytes")[1],
            "picture" => command.fetch("raw_bytes")[1],
            "scale" => (command.fetch("opcode") >> 3) & 0x07,
          )
        when 4
          params = command.fetch("raw_bytes")[1..]
          command.merge(
            "value" => command.fetch("opcode") >> 3,
            "params" => params,
            "character" => params[0],
            "character_x" => params[1],
            "character_y" => params[2],
          )
        when 5
          control = (command.fetch("opcode") & 0x80) != 0 ? "bright" : "paper"
          control_code = control == "bright" ? 19 : 17
          control_value = colour_control_value(command.fetch("opcode"))
          command.merge(
            "value" => command.fetch("opcode") >> 3,
            "control" => control,
            "control_code" => control_code,
            "control_value" => control_value,
          )
        when 6
          control = (command.fetch("opcode") & 0x80) != 0 ? "flash" : "ink"
          control_code = control == "flash" ? 18 : 16
          control_value = colour_control_value(command.fetch("opcode"))
          command.merge(
            "value" => command.fetch("opcode") >> 3,
            "control" => control,
            "control_code" => control_code,
            "control_value" => control_value,
          )
        when 7
          command.merge("value" => command.fetch("opcode") >> 3)
        else
          command
        end
      end

      def trailing_command(offset, bytes)
        {
          "offset" => offset,
          "opcode" => bytes&.first,
          "family" => bytes&.first ? bytes.first & 0x07 : nil,
          "name" => "truncated_command",
          "raw_bytes" => bytes || [],
        }
      end

      def absolute_target(command)
        {
          "x" => command.fetch("raw_bytes")[1],
          "y" => command.fetch("raw_bytes")[2],
        }
      end

      def signed_relative_delta(command)
        raw_bytes = command.fetch("raw_bytes")
        opcode = command.fetch("opcode")
        dx = raw_bytes[1] || 0
        dy = raw_bytes[2] || 0
        dx = -dx if (opcode & 0x40) != 0
        dy = -dy if (opcode & 0x80) != 0

        {
          "dx" => dx,
          "dy" => dy,
        }
      end

      def inverse_bit?(opcode)
        (opcode & 0x10) != 0
      end

      def over_bit?(opcode)
        (opcode & 0x08) != 0
      end

      def pixel_neutral_effect?(opcode)
        (opcode & EFFECT_MASK) == PIXEL_NEUTRAL_EFFECT
      end

      def pixel_effect(opcode)
        return "move" if pixel_neutral_effect?(opcode)
        return "toggle" if over_bit?(opcode)
        return "clear" if inverse_bit?(opcode)

        "set"
      end

      def colour_control_value(opcode)
        ((opcode >> 3) & 0x0F)
      end

      def relative_target(point, delta)
        {
          "x" => point.fetch("x") + delta.fetch("dx"),
          "y" => point.fetch("y") + delta.fetch("dy"),
        }
      end

      def family_two_command_name(opcode)
        return "attribute_block" if opcode == 0x12
        return "shade_fill" if (opcode & 0x20) != 0

        "flood_fill"
      end

      def family_two_attribute_block(command)
        raw_bytes = command.fetch("raw_bytes")
        return nil unless command.fetch("opcode") == 0x12 && raw_bytes.length >= 5

        {
          "attribute_x" => raw_bytes[3],
          "attribute_y" => raw_bytes[4],
          "width_attributes" => raw_bytes[2] + 1,
          "height_attributes" => raw_bytes[1] + 1
        }
      end

      def family_two_pattern_byte(command)
        command.fetch("raw_bytes")[3]
      end

      def family_two_shade_pattern(command)
        pattern_byte = family_two_pattern_byte(command)
        return nil unless pattern_byte

        {
          "first" => (pattern_byte >> 4) & 0x0F,
          "second" => pattern_byte & 0x0F,
        }
      end

      def out_of_range?(command)
        point = command["point_after"]
        return false unless point

        point.fetch("x").negative? || point.fetch("x") > 255 || point.fetch("y").negative? || point.fetch("y") > 191
      end

      def out_of_range_warning(command)
        point = command.fetch("point_after")
        "point out of screen range at offset #{command.fetch("offset")}: x=#{point.fetch("x")} y=#{point.fetch("y")}"
      end

      def signed_byte(value)
        value >= 128 ? value - 256 : value
      end
    end
  end
end
