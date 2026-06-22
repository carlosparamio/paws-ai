# frozen_string_literal: true

require "spec_helper"
require "paws/graphics/shade_pattern"

RSpec.describe PAWS::Graphics::ShadePattern do
  it "renders PAW nibble-table shade bytes" do
    expect(described_class.pixel?(0xFF, 1, 1)).to be true
    expect(described_class.pixel?(0x00, 0, 0)).to be true
    expect(described_class.pixel?(0x00, 1, 0)).to be false
    expect(described_class.pixel?(0x10, 0, 0)).to be true
    expect(described_class.pixel?(0x10, 1, 0)).to be true
    expect(described_class.pixel?(0x10, 3, 0)).to be false
    expect(described_class.pixel?(0x22, 0, 0)).to be true
    expect(described_class.pixel?(0x22, 0, 2)).to be false
    expect(described_class.pixel?(0x75, 1, 0)).to be true
    expect(described_class.pixel?(0x75, 3, 0)).to be true
    expect(described_class.pixel?(0x75, 5, 0)).to be true
    expect(described_class.pixel?(0x75, 2, 0)).to be false
    expect(described_class.pixel?(0x75, 7, 0)).to be false
  end

  it "combines both nibbles with OR semantics" do
    expect(described_class.pixel?(0x0F, 2, 1)).to be true
    expect(described_class.pixel?(0x77, 1, 0)).to be true
    expect(described_class.pixel?(0x77, 3, 0)).to be false
    expect(described_class.pixel?(0x77, 5, 0)).to be true
    expect(described_class.pixel?(nil, 2, 1)).to be false
  end

  it "uses extracted PAW shade tables when supplied" do
    patterns = {
      0 => [0b10000000, 0, 0, 0, 0, 0, 0, 0],
      1 => [0b01000000, 0, 0, 0, 0, 0, 0, 0],
    }

    expect(described_class.pixel?(0x01, 0, 0, patterns: patterns)).to be true
    expect(described_class.pixel?(0x01, 1, 0, patterns: patterns)).to be true
    expect(described_class.pixel?(0x01, 2, 0, patterns: patterns)).to be false
    expect(described_class.pixel?(0x01, 2, 0, patterns: patterns, inverse: true)).to be true
  end
end
