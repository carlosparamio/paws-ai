# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/repository"

RSpec.describe PAWS::GameData::Repository do
  let(:raw_data) do
    {
      locations: [{ description: "Room" }],
      messages: { 1 => { text: "Message" } },
      system_messages: ["SM0"],
      objects: [{ name: "Lamp", description: "a lamp" }],
      vocabulary: [
        { id: 10, word: "LOOK", type_id: 0 },
        { id: 10, word: "VIEW", type_id: 2 },
      ],
      processes: [
        { id: 0, entries: [] },
        { id: 7, entries: [{ verb: 10 }] },
      ],
    }
  end

  subject(:repository) { described_class.new(raw_data) }

  it "normalizes symbol keys once at the game data boundary" do
    expect(repository["locations"]).to eq([{ "description" => "Room" }])
    expect(repository.message_text(1)).to eq("Message")
  end

  it "looks up common game data entities" do
    expect(repository.location_text(0)).to eq("Room")
    expect(repository.system_message_text(0)).to eq("SM0")
    expect(repository.object_text(0)).to eq("Lamp")
  end

  it "hides process array/hash lookup differences" do
    expect(repository.process(7)).to eq("id" => 7, "entries" => [{ "verb" => 10 }])
    expect(described_class.new(processes: { "7" => { id: 7 } }).process(7)).to eq("id" => 7)
  end

  it "looks up vocabulary by word, id, and preferred type" do
    expect(repository.vocabulary_entry_for_word("look")["id"]).to eq(10)
    expect(repository.vocabulary_word(10, 2)).to eq("VIEW")
  end
end
