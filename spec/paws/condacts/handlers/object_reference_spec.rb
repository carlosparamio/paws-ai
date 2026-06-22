# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::ObjectReference do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 8 },
        { "initial_location" => PAWS::GameState::LOC_CARRIED },
        { "initial_location" => 9 },
      ],
    })
  end
  let(:game_data) do
    {
      "objects" => [
        { "noun_id" => 10, "adjective_id" => 255 },
        { "noun_id" => 10, "adjective_id" => 255 },
        { "noun_id" => 20, "adjective_id" => 7 },
      ],
    }
  end
  let(:engine) { instance_double(PAWS::Engine, state: state, game_data: game_data) }
  let(:object_reference) { instance_spy(PAWS::ObjectReferenceState) }

  before do
    described_class.register(
      registry,
      engine,
      object_reference: object_reference,
    )
  end

  it "sets the referred object to 255 for wildcard nouns" do
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 255)

    expect(registry.call("WHATO")).to eq(:ok)

    expect(state.get_flag(PAWS::GameState::FLAG_REFERRED_OBJECT)).to eq(255)
    expect(object_reference).not_to have_received(:update)
  end

  it "prefers the current referred object when it still matches" do
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
    state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
    state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 0)

    expect(registry.call("WHATO")).to eq(:ok)

    expect(object_reference).to have_received(:update).with(0)
  end

  it "falls back to present matches, then first matches, then no object" do
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
    state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
    state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 99)

    expect(registry.call("WHATO")).to eq(:ok)
    expect(object_reference).to have_received(:update).with(1)

    state.set_object_location(1, 12)
    expect(registry.call("WHATO")).to eq(:ok)
    expect(object_reference).to have_received(:update).with(0)

    state.set_flag(PAWS::GameState::FLAG_NOUN1, 200)
    expect(registry.call("WHATO")).to eq(:ok)
    expect(object_reference).to have_received(:update).with(255)
  end

  it "moves and weighs referred objects" do
    state.set_flag(PAWS::GameState::FLAG_REFERRED_OBJECT, 2)
    expect(registry.call("PUTO", [4])).to eq(PAWS::ExecutionResult.ok("object 2 moved to 4"))
    expect(state.object_at(2)).to eq(4)

    expect(registry.call("WEIGH", [2, 60])).to eq(:ok)
    expect(state.get_flag(60)).to eq(state.object_weight(2))
    expect(object_reference).to have_received(:update).with(2).twice
  end
end
