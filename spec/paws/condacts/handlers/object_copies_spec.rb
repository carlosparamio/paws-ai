# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::ObjectCopies do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 3 },
        { "initial_location" => 9 },
      ],
    })
  end
  let(:engine) { instance_double(PAWS::Engine, state: state) }
  let(:object_reference) { instance_spy(PAWS::ObjectReferenceState) }

  before do
    described_class.register(
      registry,
      engine,
      object_reference: object_reference,
    )
  end

  it "copies object locations into flags" do
    expect(registry.call("COPYOF", [0, 50])).to eq(:ok)

    expect(state.get_flag(50)).to eq(3)
  end

  it "copies object locations between objects and updates the referred object" do
    expect(registry.call("COPYOO", [1, 0])).to eq(:ok)

    expect(state.object_at(0)).to eq(9)
    expect(object_reference).to have_received(:update).with(0)
  end

  it "copies flag values into object locations and updates the referred object" do
    state.set_flag(60, 12)

    expect(registry.call("COPYFO", [60, 1])).to eq(:ok)

    expect(state.object_at(1)).to eq(12)
    expect(object_reference).to have_received(:update).with(1)
  end
end
