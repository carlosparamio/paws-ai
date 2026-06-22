# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/entry_matcher"

RSpec.describe PAWS::EntryMatcher do
  let(:state) { PAWS::GameState.new({ "objects" => [] }) }
  subject(:matcher) { described_class.new(state) }

  it "matches exact verb and noun values from the logical sentence flags" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 32)
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 25)

    expect(matcher.matches?({ "verb" => 32, "noun" => 25 }, mode: :response)).to be true
    expect(matcher.matches?({ "verb" => 32, "noun" => 26 }, mode: :response)).to be false
  end

  it "matches PAWS wildcard entry words and parser star flags" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 99)
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 88)

    expect(matcher.matches?({ "verb" => 0, "noun" => 1 }, mode: :response)).to be true
    expect(matcher.matches?({ "verb" => 255, "noun" => 255 }, mode: :response)).to be true

    state.set_flag(PAWS::GameState::FLAG_VERB, 1)
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 1)

    expect(matcher.matches?({ "verb" => 42, "noun" => 43 }, mode: :response)).to be true
  end

  it "honors explicit verb and noun flags in automatic processes" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 1)
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 20)

    expect(matcher.matches?({ "verb" => 1, "noun" => 20 }, mode: :automatic)).to be true
    expect(matcher.matches?({ "verb" => 1, "noun" => 21 }, mode: :automatic)).to be false
  end

  it "keeps Espia Don description entries gated by the Don noun" do
    game_data = JSON.parse(File.read(File.expand_path("../../../games/espia.json", __dir__)))
    process = game_data["processes"].find { |entry| entry["id"] == 1 }
    don_entry = process["entries"].find { |entry| entry["noun"] == 25 }

    state.set_flag(PAWS::GameState::FLAG_VERB, 255)
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 25)

    expect(don_entry).not_to be_nil
    expect(matcher.matches?(don_entry, mode: :automatic)).to be true

    state.set_flag(PAWS::GameState::FLAG_NOUN1, 86)
    expect(matcher.matches?(don_entry, mode: :automatic)).to be false
  end
end
