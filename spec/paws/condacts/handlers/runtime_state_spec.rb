# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::RuntimeState do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:interface) { instance_double(PAWS::Interface) }
  let(:state) { PAWS::GameState.new({ "objects" => [] }) }
  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      interface: interface,
    )
  end
  let(:random_values) { [3] }

  before do
    described_class.register(
      registry,
      engine,
      random: ->(_limit) { random_values.shift || 0 },
    )
  end

  it "handles flag arithmetic and random values" do
    state.set_flag(10, 8)
    state.set_flag(11, 3)

    expect(registry.call("ADD", [10, 11])).to eq(:ok)
    expect(state.get_flag(10)).to eq(11)

    expect(registry.call("SUB", [10, 11])).to eq(:ok)
    expect(state.get_flag(10)).to eq(8)

    expect(registry.call("RANDOM", [12, 5])).to eq(:ok)
    expect(state.get_flag(12)).to eq(3)
  end

  it "sets runtime capacity, weight, and timer flags" do
    allow(state).to receive(:total_carried_weight).and_return(42)

    expect(registry.call("ABILITY", [5, 20])).to eq(:ok)
    expect(state.get_flag(PAWS::GameState::FLAG_MAX_CARRIED)).to eq(5)
    expect(state.get_flag(PAWS::GameState::FLAG_MAX_WEIGHT)).to eq(20)

    expect(registry.call("WEIGHT", [30])).to eq(:ok)
    expect(state.get_flag(30)).to eq(42)

    expect(registry.call("TIME", [10, 128])).to eq(:ok)
    expect(state.get_flag(PAWS::GameState::FLAG_TIMEOUT_LENGTH)).to eq(10)
    expect(state.get_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS)).to eq(128)
  end

  it "moves through the connection table and reports missing exits" do
    state.location = 1
    state.set_connection(1, 2, 9)

    expect(registry.call("MOVE", [2])).to eq(:ok)
    expect(state.location).to eq(9)

    expect(registry.call("MOVE", [3])).to eq(PAWS::ExecutionResult.failed("no connection"))
  end

  it "saves and restores the current location" do
    state.location = 4
    expect(registry.call("SAVEAT")).to eq(:ok)

    state.location = 7
    expect(registry.call("BACKAT")).to eq(:ok)
    expect(state.location).to eq(4)
  end

  it "reads numeric input and clears text/parser-related state" do
    expect(interface).to receive(:get_input).and_return("300")
    expect(engine).to receive(:clear_phrases)

    expect(registry.call("INPUT", [40])).to eq(:ok)
    expect(state.get_flag(40)).to eq(44)

    expect(registry.call("NEWTEXT")).to eq(:ok)

    state.set_flag(41, 99)
    expect(registry.call("RESET_FLAG", [41])).to eq(:ok)
    expect(state.get_flag(41)).to eq(0)
  end
end
