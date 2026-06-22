# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/location_ref"

RSpec.describe PAWS::LocationRef do
  describe ".parse" do
    it "parses normal numeric locations" do
      ref = described_class.parse(42)

      expect(ref).to be_numeric
      expect(ref).not_to be_special
      expect(ref.resolve(current_location: 7)).to eq(42)
      expect(ref.label).to eq("L42")
    end

    it "parses PAWS special object locations" do
      expect(described_class.parse(252)).to be_not_created
      expect(described_class.parse(253)).to be_worn
      expect(described_class.parse(254)).to be_carried
    end

    it "treats HERE and 255 as the current player location" do
      expect(described_class.parse("HERE")).to eq(described_class.parse(255))
      expect(described_class.parse("HERE")).to be_here
      expect(described_class.parse(255).resolve(current_location: 12)).to eq(12)
    end

    it "provides stable labels for debugger output" do
      expect(described_class.parse(252).label).to eq("NOT_CREATED")
      expect(described_class.parse(253).label).to eq("WORN")
      expect(described_class.parse(254).label).to eq("CARRIED")
      expect(described_class.parse(255).label).to eq("HERE")
    end

    it "has readable inspect output for breakpoint dumps" do
      expect(described_class.parse("HERE").inspect).to eq("HERE")
      expect(described_class.parse(254).inspect).to eq("254")
    end
  end

  describe ".object_location_name" do
    it "returns serializer names for special object locations" do
      expect(described_class.object_location_name(252)).to eq(:not_created)
      expect(described_class.object_location_name(253)).to eq(:worn)
      expect(described_class.object_location_name(254)).to eq(:carried)
    end

    it "does not treat HERE as an initial object location name" do
      expect(described_class.object_location_name(255)).to be_nil
      expect(described_class.object_location_name(12)).to be_nil
    end
  end

  describe "#matches?" do
    it "matches normal and special numeric locations" do
      expect(described_class.parse(254).matches?(254)).to be true
      expect(described_class.parse(254).matches?(253)).to be false
    end

    it "matches HERE against the current numeric player location" do
      ref = described_class.parse("HERE")

      expect(ref.matches?(5, current_location: 5)).to be true
      expect(ref.matches?(6, current_location: 5)).to be false
      expect(ref.matches?("HERE")).to be true
    end
  end
end
