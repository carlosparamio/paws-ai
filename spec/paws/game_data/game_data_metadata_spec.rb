# frozen_string_literal: true

require "spec_helper"

RSpec.describe "PAWS game data metadata" do
  it "exposes condact names and arity for snapshot extraction" do
    expect(PAWS::GameData::CondactMetadata.fetch(85)).to eq(name: "DOALL", params: 1)
    expect(PAWS::GameData::CondactMetadata.fetch(240)).to be_nil
  end

  it "labels vocabulary type ids and falls back for unknown ids" do
    expect(PAWS::GameData::VocabularyMetadata.type_name(2)).to eq("noun")
    expect(PAWS::GameData::VocabularyMetadata.type_name(99)).to eq("unknown")
  end

  it "exposes metadata through explicit game data modules" do
    expect(PAWS::GameData::CondactMetadata::DEFINITIONS).to include(47 => hash_including(name: "SET"))
    expect(PAWS::GameData::VocabularyMetadata::TYPES).to include(0 => "verb")
  end
end
