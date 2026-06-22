# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/sna_loader"
require "paws/game_data/charset_extractor"

RSpec.describe PAWS::GameData::CharsetExtractor do
  let(:memory) { Hash.new(0) }
  let(:sna) do
    instance_double(
      PAWS::SNALoader,
      peek: nil,
    )
  end

  before do
    allow(sna).to receive(:peek) { |addr| memory[addr] }
  end

  it "extracts 1-based PAWS charset banks for character codes 32..127" do
    base = 50_000
    memory[base] = 0b00111100
    memory[base + 1] = 0b01000010
    second_bank = base + described_class::BANK_SIZE
    memory[second_bank + (65 - 32) * 8] = 0b11110000

    data = described_class.new(sna: sna).extract("count" => 2, "address" => base)

    expect(data).to include(
      "count" => 2,
      "address" => base,
      "first_char" => 32,
      "bytes_per_char" => 8,
    )
    expect(data["entries"].map { |entry| entry["id"] }).to eq([1, 2])
    expect(data["entries"][0]["glyphs"]["32"].first(2)).to eq([0b00111100, 0b01000010])
    expect(data["entries"][1]["glyphs"]["65"].first).to eq(0b11110000)
  end

  it "extracts Spectrum UDG glyphs from the system variable pointer" do
    udg_address = 52_000
    memory[described_class::SYSVAR_UDG] = udg_address & 0xFF
    memory[described_class::SYSVAR_UDG + 1] = udg_address >> 8
    memory[udg_address] = 0b11110000
    memory[udg_address + described_class::BYTES_PER_CHAR] = 0b00001111

    data = described_class.new(sna: sna).extract_udgs

    expect(data).to include(
      "address" => udg_address,
      "first_char" => 144,
      "bytes_per_char" => 8,
    )
    expect(data["glyphs"]["144"].first).to eq(0b11110000)
    expect(data["glyphs"]["145"].first).to eq(0b00001111)
  end

  it "extracts PAW shade patterns from charset set 0 in the main database" do
    main_top = 40_000
    shade_address = main_top + described_class::SHADE_TABLE_OFFSET
    memory[shade_address] = 0b10000000
    memory[shade_address + described_class::BYTES_PER_CHAR] = 0b01000000

    data = described_class.new(sna: sna).extract_shade_patterns(main_top)

    expect(data).to include(
      "address" => shade_address,
      "first_pattern" => 0,
      "bytes_per_pattern" => 8,
    )
    expect(data["patterns"]["0"].first).to eq(0b10000000)
    expect(data["patterns"]["1"].first).to eq(0b01000000)
  end

  it "ignores invalid ranges" do
    data = described_class.new(sna: sna).extract("count" => 8, "address" => 65_000)

    expect(data).to be_nil
  end

  it "ignores invalid UDG ranges" do
    memory[described_class::SYSVAR_UDG] = 120
    memory[described_class::SYSVAR_UDG + 1] = 255

    data = described_class.new(sna: sna).extract_udgs

    expect(data).to be_nil
  end

  it "ignores invalid shade pattern ranges" do
    data = described_class.new(sna: sna).extract_shade_patterns(65_500)

    expect(data).to be_nil
  end
end
