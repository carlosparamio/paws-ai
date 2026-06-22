# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/picture_extractor"

RSpec.describe PAWS::GameData::PictureExtractor do
  let(:sna) { instance_double(PAWS::SNALoader) }
  let(:memory) { Hash.new(0) }

  def set_word(addr, value)
    memory[addr] = value & 0xFF
    memory[addr + 1] = (value >> 8) & 0xFF
  end

  before do
    allow(sna).to receive(:peek) { |addr| memory[addr] }
    allow(sna).to receive(:peek_word) { |addr| memory[addr] | (memory[addr + 1] << 8) }
  end

  it "extracts raw drawstrings and picture flags without decoding commands" do
    set_word(1010, 1000)
    set_word(1012, 1003)
    memory[1000] = 0x11
    memory[1001] = 0x22
    memory[1002] = 0xFF
    memory[1003] = 0x33
    memory[1004] = 0xFF
    memory[1020] = 0x87
    memory[1021] = 0x04

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1000,
      picture_table: 1010,
      location_flags: 1020,
      graphics_end: 1022,
      location_count: 2,
    )

    expect(pictures).to include(
      "drawstrings_start" => 1000,
      "picture_table" => 1010,
      "location_flags" => 1020,
      "graphics_end" => 1022,
    )
    expect(pictures["summary"]).to include(
      "entry_count" => 2,
      "drawable_count" => 1,
      "raw_byte_count" => 10,
    )
    expect(pictures["entries"][0]).to include(
      "id" => 0,
      "pointer" => 1000,
      "length" => 3,
      "location_flag" => 0x87,
      "drawable" => true,
      "paper" => 0,
      "ink" => 7,
      "raw_bytes" => [0x11, 0x22, 0xFF],
    )
    expect(pictures["entries"][0]["decoded_commands"]).not_to be_empty
    expect(pictures["entries"][1]).to include(
      "id" => 1,
      "pointer" => 1003,
      "length" => 7,
      "drawable" => false,
      "raw_bytes" => [0x33, 0xFF, 0, 0, 0, 0, 0],
    )
  end

  it "returns nil for empty graphics placeholders" do
    set_word(1010, 1000)
    memory[1020] = 0x07

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1000,
      picture_table: 1010,
      location_flags: 1020,
      graphics_end: 1021,
      location_count: 1,
    )

    expect(pictures).to be_nil
  end

  it "supports PAW v1 layouts with picture flags before drawstrings" do
    memory[1000] = 0x87
    memory[1001] = 0x04
    memory[1002] = 0x11
    memory[1003] = 0x22
    memory[1004] = 0xFF
    memory[1005] = 0x33
    memory[1006] = 0xFF
    set_word(1010, 1002)
    set_word(1012, 1005)

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1002,
      picture_table: 1010,
      location_flags: 1000,
      graphics_end: 1014,
      location_count: 2,
      flags_before_drawstrings: true,
    )

    expect(pictures["summary"]).to include(
      "entry_count" => 2,
      "drawable_count" => 1,
      "raw_byte_count" => 8,
    )
    expect(pictures["entries"][0]).to include(
      "location_flag" => 0x87,
      "raw_bytes" => [0x11, 0x22, 0xFF],
    )
    expect(pictures["entries"][1]).to include(
      "location_flag" => 0x04,
      "raw_bytes" => [0x33, 0xFF, 0, 0, 0],
    )
  end

  it "supports layouts with a picture table but no per-location flags" do
    memory[1000] = 0x07
    memory[1001] = 0x19
    memory[1002] = 0x2B
    memory[1003] = 0xAF
    memory[1004] = 0x07
    set_word(1010, 1000)
    set_word(1012, 1001)

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1000,
      picture_table: 1010,
      location_flags: nil,
      graphics_end: 1014,
      location_count: 2,
    )

    expect(pictures).to include(
      "drawstrings_start" => 1000,
      "location_flags" => nil,
    )
    expect(pictures["entries"][0]).to include(
      "pointer" => 1000,
      "effective_pointer" => 1000,
      "drawable" => false,
      "raw_bytes" => [0x07],
    )
    expect(pictures["entries"][1]).to include(
      "pointer" => 1001,
      "effective_pointer" => 1001,
      "drawable" => true,
      "raw_bytes" => [0x19, 0x2B, 0xAF, 0x07, 0, 0, 0, 0, 0],
    )
  end

  it "assigns a leading PAW v1 drawstring gap to the last leading placeholder pointer" do
    memory[1000] = 0x07
    memory[1001] = 0x19
    memory[1002] = 0xAA
    memory[1003] = 0xBB
    memory[1004] = 0x07
    memory[1005] = 0xCC
    memory[1006] = 0x07
    set_word(1010, 1000)
    set_word(1012, 1001)
    set_word(1014, 1005)

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1002,
      picture_table: 1010,
      location_flags: 1000,
      graphics_end: 1016,
      location_count: 3,
      flags_before_drawstrings: true,
    )

    expect(pictures["entries"][0]).to include(
      "pointer" => 1000,
      "effective_pointer" => nil,
      "raw_bytes" => [],
    )
    expect(pictures["entries"][1]).to include(
      "pointer" => 1001,
      "effective_pointer" => 1002,
      "raw_bytes" => [0xAA, 0xBB, 0x07],
    )
    expect(pictures["entries"][2]).to include(
      "pointer" => 1005,
      "effective_pointer" => 1005,
      "raw_bytes" => [0xCC, 0x07, 0, 0, 0],
    )
  end

  it "warns when a decoded GOSUB points outside the picture table" do
    set_word(1010, 1000)
    memory[1000] = 0x03
    memory[1001] = 0x02
    memory[1002] = 0x07
    memory[1020] = 0x87

    pictures = described_class.new(sna: sna).extract(
      drawstrings_start: 1000,
      picture_table: 1010,
      location_flags: 1020,
      graphics_end: 1021,
      location_count: 1,
    )

    expect(pictures["entries"][0]["decode_warnings"]).to include(
      "gosub picture out of table at offset 0: picture=2 location_count=1"
    )
  end
end
