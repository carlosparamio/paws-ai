# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::FlowControl do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) { PAWS::GameState.new({ "objects" => [] }) }
  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      output_sysmess: nil,
      set_done: nil,
      log: nil,
      request_description: nil,
      interface: nil,
    )
  end
  let(:execution_context) { PAWS::ProcessExecutionContext.new }
  let(:process_control) { instance_spy(PAWS::ProcessControl) }

  before do
    described_class.register(
      registry,
      engine,
      execution_context: execution_context,
      process_control: process_control,
    )
  end

  it "marks DONE and NOTDONE through the execution context" do
    execution_context.push_frame

    expect(registry.call("DONE")).to eq(:ok)
    expect(execution_context.done?).to be true

    expect(registry.call("NOTDONE")).to eq(:ok)
    expect(execution_context.done?).to be false
  end

  it "outputs OK and marks the engine done" do
    execution_context.push_frame

    expect(registry.call("OK")).to eq(:ok)
    expect(registry.call(23)).to eq(:ok)

    expect(engine).to have_received(:output_sysmess).with(15).twice
    expect(engine).to have_received(:set_done).twice
    expect(execution_context.done?).to be true
  end

  it "requests a description jump" do
    catch(:desc_jump) { registry.call("DESC") }

    expect(engine).to have_received(:request_description)
  end

  it "changes location and runs nested process tables" do
    expect(registry.call("GOTO", [12])).to eq(:ok)
    expect(state.location).to eq(12)

    expect(registry.call("PROCESS", [3])).to eq(:ok)
    expect(process_control).to have_received(:run_subprocess).with(3)
  end
end
