# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/serializer"
require "tempfile"

RSpec.describe PAWS::GameData::Serializer do
  let(:game_data) do
    {
      "game" => { "title" => "Test" },
      "vocabulary" => [{ "word" => "norte", "id" => 1 }],
    }
  end

  describe ".to_json" do
    it "converts hash to pretty JSON by default" do
      json = described_class.to_json(game_data)
      expect(json).to include('"title": "Test"')
      expect(json).to include("\n")
    end

    it "converts hash to compact JSON when pretty is false" do
      json = described_class.to_json(game_data, pretty: false)
      expect(json).not_to include("\n")
    end
  end

  describe ".from_json" do
    it "parses JSON and symbolizes keys" do
      json = '{"game": {"title": "Test"}}'
      data = described_class.from_json(json)
      expect(data[:game][:title]).to eq("Test")
    end
  end

  describe ".save and .load" do
    it "saves to and loads from a file" do
      Tempfile.create(["game", ".json"]) do |file|
        described_class.save(game_data, file.path)
        loaded = described_class.load(file.path)

        # Result of load uses symbolized keys
        expect(loaded[:game][:title]).to eq("Test")
      end
    end
  end
end
