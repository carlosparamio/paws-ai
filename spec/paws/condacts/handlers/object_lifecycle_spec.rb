# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::ObjectLifecycle do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 1 },
        { "initial_location" => PAWS::GameState::LOC_CARRIED },
      ],
    })
  end
  let(:game_data) do
    {
      "objects" => [
        { "location" => 2 },
        { "location" => 3 },
      ],
    }
  end
  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      get_data_item: nil,
    )
  end
  let(:object_reference) { instance_spy(PAWS::ObjectReferenceState) }

  before do
    allow(engine).to receive(:get_data_item) { |key, idx| game_data[key][idx] }
    registry.register("DESC") { :ok }
    described_class.register(
      registry,
      engine,
      object_reference: object_reference,
    )
  end

  it "creates and destroys objects" do
    state.location = 5

    expect(registry.call("CREATE", [1])).to eq(:ok)
    expect(state.object_at(1)).to eq(5)

    expect(registry.call("DESTROY", [1])).to eq(:ok)
    expect(state.object_at(1)).to eq(PAWS::GameState::LOC_NOT_CREATED)
    expect(object_reference).to have_received(:update).with(1).twice
  end

  it "swaps and places object locations" do
    expect(registry.call("SWAP", [0, 1])).to eq(:ok)
    expect(state.object_at(0)).to eq(PAWS::GameState::LOC_CARRIED)
    expect(state.object_at(1)).to eq(1)

    expect(registry.call("PLACE", [0, 8])).to eq(:ok)
    expect(state.object_at(0)).to eq(8)
    expect(object_reference).to have_received(:update).with(1)
    expect(object_reference).to have_received(:update).with(0)
  end

  it "resets objects and requests a description" do
    state.set_object_location(0, 5)
    state.set_object_location(1, PAWS::GameState::LOC_CARRIED)

    expect(registry.call("RESET", [10])).to eq(:ok)

    expect(state.object_at(0)).to eq(2)
    expect(state.object_at(1)).to eq(10)
    expect(state.location).to eq(10)
  end
end
