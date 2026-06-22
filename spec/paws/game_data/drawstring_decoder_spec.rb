# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/drawstring_decoder"

RSpec.describe PAWS::GameData::DrawstringDecoder do
  it "decodes semantic commands while preserving raw bytes" do
    decoded = described_class.new.decode([0x00, 0x08, 0x50, 0x03, 0x05, 0x07])

    expect(decoded["warnings"]).to eq([])
    expect(decoded["consumed_bytes"]).to eq(6)
    expect(decoded["commands"]).to match(
      [
        hash_including(
          "offset" => 0,
          "opcode" => 0x00,
          "family" => 0,
          "name" => "plot",
          "raw_bytes" => [0x00, 0x08, 0x50],
          "point_before" => { "x" => 0, "y" => 0 },
          "x" => 0x08,
          "y" => 0x50,
          "point_after" => { "x" => 0x08, "y" => 0x50 },
          "pixel_effect" => "set",
        ),
        hash_including(
          "offset" => 3,
          "opcode" => 0x03,
          "family" => 3,
          "name" => "gosub",
          "raw_bytes" => [0x03, 0x05],
          "picture_id" => 5,
          "picture" => 5,
          "scale" => 0,
        ),
        hash_including(
          "offset" => 5,
          "opcode" => 0x07,
          "family" => 7,
          "name" => "end_marker",
          "raw_bytes" => [0x07],
        ),
      ]
    )
  end

  it "treats 0x07 as a one-byte command unless it is the final marker" do
    decoded = described_class.new.decode([0x07, 0x01, 0x02, 0x03])

    expect(decoded["warnings"]).to eq([])
    expect(decoded["commands"][0]).to include(
      "offset" => 0,
      "name" => "control",
      "raw_bytes" => [0x07],
      "value" => 0,
    )
  end

  it "tracks relative points for family 1 commands" do
    decoded = described_class.new.decode([0x00, 0x20, 0x30, 0x41, 0x02, 0x04, 0x07])

    expect(decoded["commands"][1]).to include(
      "name" => "line",
      "dx" => -2,
      "dy" => 4,
      "point_before" => { "x" => 0x20, "y" => 0x30 },
      "point_after" => { "x" => 0x1E, "y" => 0x34 },
      "pixel_effect" => "set",
    )
  end

  it "identifies pixel-neutral absolute and relative moves" do
    decoded = described_class.new.decode([0x18, 0x20, 0x30, 0x19, 0x04, 0x05, 0x07])

    expect(decoded["commands"][0]).to include(
      "name" => "absolute_move",
      "point_after" => { "x" => 0x20, "y" => 0x30 },
      "inverse_bit" => true,
      "over_bit" => true,
      "pixel_effect" => "move",
    )
    expect(decoded["commands"][1]).to include(
      "name" => "relative_move",
      "point_before" => { "x" => 0x20, "y" => 0x30 },
      "point_after" => { "x" => 0x24, "y" => 0x35 },
      "inverse_bit" => true,
      "over_bit" => true,
      "pixel_effect" => "move",
    )
  end

  it "maps PAW effect bits to INVERSE and OVER" do
    decoded = described_class.new.decode([0x08, 0x20, 0x30, 0x10, 0x21, 0x31, 0x07])

    expect(decoded["commands"][0]).to include(
      "inverse_bit" => false,
      "over_bit" => true,
      "pixel_effect" => "toggle",
    )
    expect(decoded["commands"][1]).to include(
      "inverse_bit" => true,
      "over_bit" => false,
      "pixel_effect" => "clear",
    )
  end

  it "exposes definitive family 2 shade fill semantics" do
    decoded = described_class.new.decode([0x22, 0x02, 0x03, 0x0A, 0x07])
    command = decoded["commands"].first

    expect(command).to include(
      "name" => "shade_fill",
      "params" => [0x02, 0x03, 0x0A],
      "pattern_byte" => 0x0A,
      "shade_pattern" => { "first" => 0, "second" => 10 },
      "dx" => 2,
      "dy" => 3,
      "tip" => { "x" => 2, "y" => 3 },
    )
    expect(command).not_to have_key("operation_alternatives")
    expect(command).not_to have_key("possible_parse_lengths")
    expect(command).not_to have_key("current_parse_length")
  end

  it "keeps the graphics point unchanged after family 2 fill endpoints" do
    decoded = described_class.new.decode(
      [
        0x00, 0x20, 0x30,
        0x0A, 0x02, 0x03,
        0x01, 0x04, 0x00,
        0x07,
      ]
    )

    expect(decoded["commands"][1]).to include(
      "name" => "flood_fill",
      "point_before" => { "x" => 0x20, "y" => 0x30 },
      "tip" => { "x" => 0x22, "y" => 0x33 },
    )
    expect(decoded["commands"][1]).not_to have_key("point_after")
    expect(decoded["commands"][2]).to include(
      "point_before" => { "x" => 0x20, "y" => 0x30 },
      "point_after" => { "x" => 0x24, "y" => 0x30 },
    )
  end

  it "uses the PAW family 2 lengths observed in the Z80 graphics routine" do
    decoded = described_class.new.decode(
      [
        0x0A, 0x01, 0x02,
        0x22, 0x03, 0x04, 0x55,
        0x12, 0x05, 0x06, 0x07, 0x08,
        0x07
      ]
    )

    expect(decoded["commands"].map { |command| [command["offset"], command["raw_bytes"]] }).to eq(
      [
        [0, [0x0A, 0x01, 0x02]],
        [3, [0x22, 0x03, 0x04, 0x55]],
        [7, [0x12, 0x05, 0x06, 0x07, 0x08]],
        [12, [0x07]],
      ]
    )
    expect(decoded["commands"][2]).to include(
      "name" => "attribute_block",
      "attribute_block" => {
        "attribute_x" => 0x07,
        "attribute_y" => 0x08,
        "width_attributes" => 0x07,
        "height_attributes" => 0x06,
      },
    )
  end

  it "uses the PAW family 4 length observed in the Z80 graphics routine" do
    decoded = described_class.new.decode([0x24, 0x20, 0x0A, 0x03, 0x01, 0x00, 0x0F, 0x07])

    expect(decoded["commands"].map { |command| [command["offset"], command["raw_bytes"]] }).to eq(
      [
        [0, [0x24, 0x20, 0x0A, 0x03]],
        [4, [0x01, 0x00, 0x0F]],
        [7, [0x07]],
      ]
    )
    expect(decoded["commands"].first).to include(
      "name" => "draw_character",
      "params" => [0x20, 0x0A, 0x03],
      "character" => 0x20,
      "character_x" => 0x0A,
      "character_y" => 0x03,
    )
    expect(decoded["commands"].first).not_to have_key("current_parse_length")
    expect(decoded["commands"][1]).to include(
      "point_before" => { "x" => 0, "y" => 0 },
      "point_after" => { "x" => 0, "y" => 0x0F },
    )
  end

  it "exposes PAW colour controls for families 5 and 6" do
    decoded = described_class.new.decode([0x2D, 0x8D, 0x16, 0x86, 0x07])

    expect(decoded["commands"][0]).to include(
      "name" => "paper",
      "control" => "paper",
      "control_code" => 17,
      "control_value" => 5,
    )
    expect(decoded["commands"][1]).to include(
      "name" => "bright",
      "control" => "bright",
      "control_code" => 19,
      "control_value" => 1,
    )
    expect(decoded["commands"][2]).to include(
      "name" => "ink",
      "control" => "ink",
      "control_code" => 16,
      "control_value" => 2,
    )
    expect(decoded["commands"][3]).to include(
      "name" => "flash",
      "control" => "flash",
      "control_code" => 18,
      "control_value" => 0,
    )
  end

  it "warns when geometry leaves the Spectrum screen" do
    decoded = described_class.new.decode([0x00, 0xFA, 0x30, 0x01, 0x08, 0x00, 0x07])

    expect(decoded["warnings"]).to include("point out of screen range at offset 3: x=258 y=48")
  end
end
