# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::Persistence do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:state) { PAWS::GameState.new({ "objects" => [] }) }
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) { { "system_messages" => { 30 => "si/no" } } }
  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      interface: interface,
      game_data: game_data,
      output_sysmess: nil,
      restart: nil,
      stop: nil,
    )
  end
  let(:execution_context) { PAWS::ProcessExecutionContext.new }

  before do
    registry.register("ANYKEY") { :ok }
    registry.register("DESC") { :ok }
    described_class.register(
      registry,
      engine,
      execution_context: execution_context,
    )
  end

  it "saves and restores RAM snapshots" do
    state.set_flag(10, 30)
    expect(registry.call("RAMSAVE")).to eq(:ok)

    state.set_flag(10, 90)
    expect(registry.call("RAMLOAD", [20])).to eq(:ok)

    expect(state.get_flag(10)).to eq(30)
  end

  it "reports failed RAM loads" do
    expect(state).to receive(:ramload).with(256).and_return(false)

    expect(registry.call("RAMLOAD", [256])).to eq(:failed)
  end

  it "delegates save and load to the interface" do
    expect(interface).to receive(:save_game).with(state)
    expect(interface).to receive(:load_game).with(engine).and_return(true)

    expect(registry.call("SAVE")).to eq(:ok)
    expect(registry.call("LOAD")).to eq(:ok)
  end

  it "runs the manual LOAD failure sequence" do
    expect(interface).to receive(:load_game).with(engine).and_return(false)

    registry.call("LOAD")

    expect(engine).to have_received(:output_sysmess).with(54, newline: true)
  end

  it "handles END by restarting or stopping, then aborting" do
    execution_context.push_frame

    expect(interface).to receive(:wait_for_key).and_return("s")
    expect(registry.call("END")).to eq(:abort)
    expect(engine).to have_received(:restart)
    expect(execution_context.done?).to be true

    execution_context.mark_notdone
    expect(interface).to receive(:wait_for_key).and_return("n")
    expect(registry.call("END")).to eq(:abort)
    expect(engine).to have_received(:stop)
    expect(execution_context.done?).to be true
  end

  it "handles QUIT confirmation" do
    execution_context.push_frame

    expect(interface).to receive(:wait_for_key).and_return("s")
    expect(registry.call("QUIT")).to eq(:ok)
    expect(engine).to have_received(:stop)

    expect(interface).to receive(:wait_for_key).and_return("n")
    expect(registry.call("QUIT")).to eq(:failed)
    expect(execution_context.done?).to be true
  end

  it "resolves accepted keys from hash, string, or fallback" do
    game_data["system_messages"][30] = { "text" => "yes/no" }
    expect(described_class.accepted_key(engine)).to eq("y")

    game_data["system_messages"][30] = "no/yes"
    expect(described_class.accepted_key(engine)).to eq("n")

    game_data["system_messages"][30] = ""
    expect(described_class.accepted_key(engine)).to eq("s")
  end
end
