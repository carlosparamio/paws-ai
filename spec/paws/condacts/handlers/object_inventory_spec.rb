# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::ObjectInventory do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 1, "weight" => 2 },
        { "initial_location" => PAWS::GameState::LOC_CARRIED, "weight" => 1, "attributes" => [15] },
        { "initial_location" => PAWS::GameState::LOC_WORN, "weight" => 1, "attributes" => [15] },
      ],
    })
  end
  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      output_sysmess: nil,
      set_done: nil,
    )
  end
  let(:object_reference) { instance_spy(PAWS::ObjectReferenceState) }
  let(:execution_context) { PAWS::ProcessExecutionContext.new }

  before do
    state.location = 1
    state.set_object_attr(1, 15, true)
    state.set_object_attr(2, 15, true)
    allow(engine).to receive(:object_text).and_return("obj")
    allow(engine).to receive(:object_placeholder_text).and_return("obj")
    described_class.register(
      registry,
      engine,
      object_reference: object_reference,
      execution_context: execution_context,
    )
    execution_context.push_frame
  end

  it "gets, drops, wears, removes, and drops all inventory objects" do
    expect(registry.call("GET", [0])).to eq(:ok)
    expect(state.object_carried?(0)).to be true

    expect(registry.call("DROP", [0])).to eq(:ok)
    expect(state.object_at(0)).to eq(1)

    expect(registry.call("WEAR", [1])).to eq(:ok)
    expect(state.object_worn?(1)).to be true

    expect(registry.call("REMOVE", [1])).to eq(:ok)
    expect(state.object_carried?(1)).to be true

    expect(registry.call("DROPALL")).to eq(:ok)
    expect(state.carried_objects).to be_empty
  end

  it "puts objects into containers and takes them out" do
    expect(registry.call("PUTIN", [1, 100])).to eq(:ok)
    expect(state.object_at(1)).to eq(100)

    expect(registry.call("TAKEOUT", [1, 100])).to eq(:ok)
    expect(state.object_carried?(1)).to be true
  end

  it "marks logical aborts and DOALL aborts" do
    state.set_flag(PAWS::GameState::FLAG_MAX_CARRIED, 1)

    expect(registry.call("GET", [0])).to eq(:failed)

    expect(execution_context.done?).to be true
    expect(execution_context.abort_doall?).to be true
    expect(engine).to have_received(:set_done)
  end
end
