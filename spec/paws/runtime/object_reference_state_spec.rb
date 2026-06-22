# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::ObjectReferenceState do
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 1, "weight" => 2 },
        { "initial_location" => PAWS::GameState::LOC_CARRIED, "weight" => 3, "attrs_lo" => 32_768 },
      ],
    })
  end
  let(:engine) { instance_double(PAWS::Engine, state: state, game_data: game_data) }
  let(:game_data) { { "objects" => [{}, {}] } }

  subject(:reference_state) { described_class.new(engine) }

  it "updates the referred-object cache flags" do
    reference_state.update(1)

    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(1)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_LOC)).to eq(PAWS::GameState::LOC_CARRIED)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_WEIGHT)).to eq(3)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_IS_CONTAINER)).to eq(0)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_IS_WEARABLE)).to eq(128)
  end

  it "clears cached flags for unknown objects" do
    reference_state.update(255)

    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(255)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_LOC)).to eq(255)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_WEIGHT)).to eq(0)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_IS_CONTAINER)).to eq(0)
    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT_IS_WEARABLE)).to eq(0)
  end
end
