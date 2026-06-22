# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::Information do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => PAWS::GameState::LOC_CARRIED },
        { "initial_location" => PAWS::GameState::LOC_WORN },
        { "initial_location" => 4 },
        { "initial_location" => 8 },
      ],
    })
  end
  let(:engine) { instance_double(PAWS::Engine, state: state) }

  before do
    described_class.register(registry, engine)
    allow(engine).to receive(:object_text) { |objno| ["Llave", "Capa", "Roca", "Caja"][objno] }
    allow(engine).to receive(:output_sysmess)
    allow(engine).to receive(:output_text)
  end

  it "renders an empty inventory and stops the current entry" do
    state.set_object_location(0, 4)
    state.set_object_location(1, 4)

    expect(registry.call("INVEN")).to eq(:done)
    expect(engine).to have_received(:output_sysmess).with(9, newline: false)
    expect(engine).to have_received(:output_sysmess).with(11, newline: true)
  end

  it "renders carried and worn inventory objects" do
    expect(registry.call("INVEN")).to eq(:done)

    expect(engine).to have_received(:output_text).with("  Llave", newline: true)
    expect(engine).to have_received(:output_text).with("  Capa", newline: false)
    expect(engine).to have_received(:output_sysmess).with(10, newline: true)
  end

  it "lists visible objects at the current location and marks listing status" do
    state.location = 4

    expect(registry.call("LISTOBJ")).to eq(:done)

    expect(engine).to have_received(:output_sysmess).with(1, newline: true)
    expect(engine).to have_received(:output_text).with("Roca", newline: true)
    expect(state.get_flag(PAWS::GameState::FLAG_LISTING_CONTROL) & 0x80).not_to be_zero
  end

  it "uses SM53 when LISTAT has no objects" do
    expect(registry.call("LISTAT", [12])).to eq(:ok)

    expect(engine).to have_received(:output_sysmess).with(53)
  end

  it "renders turns and score" do
    state.set_flag(PAWS::GameState::FLAG_TURNS_LO, 2)
    state.set_flag(30, 15)

    expect(registry.call("TURNS")).to eq(:ok)
    expect(registry.call("SCORE")).to eq(:ok)

    expect(engine).to have_received(:output_text).with("2", newline: false)
    expect(engine).to have_received(:output_sysmess).with(19, newline: false)
    expect(engine).to have_received(:output_sysmess).with(21, newline: false)
    expect(engine).to have_received(:output_text).with("15", newline: false)
    expect(engine).to have_received(:output_sysmess).with(22, newline: true)
  end
end
