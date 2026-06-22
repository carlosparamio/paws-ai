# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::Conditions do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 1 },
        { "initial_location" => PAWS::GameState::LOC_CARRIED },
        { "initial_location" => PAWS::GameState::LOC_WORN },
        { "initial_location" => 7 },
      ],
    })
  end
  let(:engine) { instance_double(PAWS::Engine, state: state) }
  let(:rolls) { [42] }

  before do
    state.location = 1
    described_class.register(registry, engine, random: ->(_range) { rolls.shift || 42 })
  end

  it "evaluates player-location conditions" do
    expect(registry.call("AT", [1])).to eq(:ok)
    expect(registry.call("AT", [3])).to eq(PAWS::ExecutionResult.failed("at location 1"))
    expect(registry.call("NOTAT", [3])).to eq(:ok)
    expect(registry.call("ATGT", [0])).to eq(:ok)
    expect(registry.call("ATLT", [2])).to eq(:ok)
  end

  it "evaluates object presence and inventory conditions" do
    expect(registry.call("PRESENT", [0])).to eq(:ok)
    expect(registry.call("PRESENT", [1])).to eq(:ok)
    expect(registry.call("PRESENT", [2])).to eq(:ok)
    expect(registry.call("ABSENT", [3])).to eq(:ok)
    expect(registry.call("CARRIED", [1])).to eq(:ok)
    expect(registry.call("NOTCARR", [0])).to eq(:ok)
    expect(registry.call("WORN", [2])).to eq(:ok)
    expect(registry.call("NOTWORN", [0])).to eq(:ok)
  end

  it "evaluates explicit object-location conditions with special location refs" do
    expect(registry.call("ISAT", [0, "HERE"])).to eq(:ok)
    expect(registry.call("ISAT", [1, PAWS::GameState::LOC_CARRIED])).to eq(:ok)
    expect(registry.call("ISNOTAT", [0, 7])).to eq(:ok)
    expect(registry.call("ISNOTAT", [3, 7])).to eq(PAWS::ExecutionResult.failed("object 3 is at 7"))
  end

  it "evaluates parser-word flag conditions" do
    state.set_flag(PAWS::GameState::FLAG_ADJECT1, 5)
    state.set_flag(PAWS::GameState::FLAG_ADVERB, 6)
    state.set_flag(PAWS::GameState::FLAG_PREP, 7)
    state.set_flag(PAWS::GameState::FLAG_NOUN2, 8)
    state.set_flag(PAWS::GameState::FLAG_ADJECT2, 9)

    expect(registry.call("ADJECT1", [5])).to eq(:ok)
    expect(registry.call("ADVERB", [6])).to eq(:ok)
    expect(registry.call("PREP", [7])).to eq(:ok)
    expect(registry.call("NOUN2", [8])).to eq(:ok)
    expect(registry.call("ADJECT2", [9])).to eq(:ok)
    expect(registry.call("ADJECT2", [1])).to eq(PAWS::ExecutionResult.failed("actual value is 9"))
  end

  it "evaluates timeout and chance conditions" do
    expect(registry.call("TIMEOUT")).to eq(PAWS::ExecutionResult.failed("timeout flag is 0"))

    state.set_flag(PAWS::GameState::FLAG_TIMEOUT_FLAGS, 0x80)
    expect(registry.call("TIMEOUT")).to eq(:ok)

    rolls.replace([42, 42])
    expect(registry.call("CHANCE", [50])).to eq(:ok)
    expect(registry.call("CHANCE", [10])).to eq(PAWS::ExecutionResult.failed("rolled 42"))
  end
end
