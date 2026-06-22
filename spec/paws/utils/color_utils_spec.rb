# frozen_string_literal: true

require "spec_helper"
require "paws/utils/color_utils"

RSpec.describe PAWS::ColorUtils do
  describe ".to_ansi" do
    it "converts known color names to ANSI symbols" do
      expect(PAWS::ColorUtils.to_ansi("black")).to eq(:black)
      expect(PAWS::ColorUtils.to_ansi("blue")).to eq(:blue)
      expect(PAWS::ColorUtils.to_ansi("red")).to eq(:red)
      expect(PAWS::ColorUtils.to_ansi("magenta")).to eq(:magenta)
      expect(PAWS::ColorUtils.to_ansi("green")).to eq(:green)
      expect(PAWS::ColorUtils.to_ansi("cyan")).to eq(:cyan)
      expect(PAWS::ColorUtils.to_ansi("yellow")).to eq(:yellow)
      expect(PAWS::ColorUtils.to_ansi("white")).to eq(:white)
    end

    it "is case-insensitive" do
      expect(PAWS::ColorUtils.to_ansi("RED")).to eq(:red)
      expect(PAWS::ColorUtils.to_ansi("Green")).to eq(:green)
    end

    it "handles symbols" do
      expect(PAWS::ColorUtils.to_ansi(:blue)).to eq(:blue)
    end

    it "defaults to white for unknown colors" do
      expect(PAWS::ColorUtils.to_ansi("unknown")).to eq(:white)
      expect(PAWS::ColorUtils.to_ansi(nil)).to eq(:white)
    end
  end

  describe ".spectrum_color_name" do
    it "resolves normal Spectrum color codes" do
      expect(PAWS::ColorUtils.spectrum_color_name(7)).to eq("white")
      expect(PAWS::ColorUtils.spectrum_color_name(4)).to eq("green")
    end

    it "resolves Spectrum contrast color 9 against the current paper" do
      expect(PAWS::ColorUtils.spectrum_color_name(9, contrast_against: 0)).to eq("white")
      expect(PAWS::ColorUtils.spectrum_color_name(9, contrast_against: 7)).to eq("black")
    end
  end
end
