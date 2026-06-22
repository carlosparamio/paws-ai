# frozen_string_literal: true

require "spec_helper"
require "paws/web/app"

RSpec.describe PAWS::Web::App do
  subject(:app) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@mapping, "game.mapping.json")
    end
  end

  describe "#load_game_data" do
    it "loads JSON game files directly without extracting snapshots" do
      allow(File).to receive(:read).with("game.json").and_return('{"game":{"title":"cached"}}')
      expect(PAWS::Extractor).not_to receive(:new)

      data = app.send(:load_game_data, "game.json")

      expect(data).to eq("game" => { "title" => "cached" })
    end

    it "extracts snapshot formats on demand using the provided mapping" do
      extractor = instance_double(PAWS::Extractor, extract: { "game" => { "title" => "live" } })
      expect(PAWS::Extractor).to receive(:new).with(mapping: "game.mapping.json").and_return(extractor)

      data = app.send(:load_game_data, "game.z80")

      expect(extractor).to have_received(:extract).with("game.z80")
      expect(data).to eq("game" => { "title" => "live" })
    end

    it "uses a sibling snapshot mapping when no mapping is provided" do
      app_without_mapping = described_class.allocate.tap do |instance|
        instance.instance_variable_set(:@mapping, nil)
      end
      extractor = instance_double(PAWS::Extractor, extract: { "game" => { "title" => "mapped" } })
      allow(File).to receive(:file?).with("game.mapping.json").and_return(true)
      expect(PAWS::Extractor).to receive(:new).with(mapping: "game.mapping.json").and_return(extractor)

      data = app_without_mapping.send(:load_game_data, "game.sna")

      expect(extractor).to have_received(:extract).with("game.sna")
      expect(data).to eq("game" => { "title" => "mapped" })
    end

    it "falls back to the default extractor mapping when no sibling mapping exists" do
      app_without_mapping = described_class.allocate.tap do |instance|
        instance.instance_variable_set(:@mapping, nil)
      end
      extractor = instance_double(PAWS::Extractor, extract: { "game" => { "title" => "default" } })
      allow(File).to receive(:file?).with("game.mapping.json").and_return(false)
      expect(PAWS::Extractor).to receive(:new).with(mapping: nil).and_return(extractor)

      data = app_without_mapping.send(:load_game_data, "game.sna")

      expect(extractor).to have_received(:extract).with("game.sna")
      expect(data).to eq("game" => { "title" => "default" })
    end
  end
end
