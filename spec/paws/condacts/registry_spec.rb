# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactRegistry do
  subject(:registry) { described_class.new }

  it "dispatches registered handlers by name or opcode" do
    calls = []
    registry.register("SET", opcode: 47) { |flag| calls << [:set, flag]; :ok }

    expect(registry.call("set", [10])).to eq(:ok)
    expect(registry.call(47, [11])).to eq(:ok)
    expect(calls).to eq([[:set, 10], [:set, 11]])
  end

  it "reports whether a condact is registered" do
    registry.register("COPYFF") { :ok }

    expect(registry).to be_registered("copyff")
    expect(registry).not_to be_registered("MESSAGE")
  end
end

RSpec.describe PAWS::CondactHandlers::Flags do
  let(:interface) { instance_double(PAWS::Interface) }
  let(:game_data) do
    {
      "locations" => [{ "description" => "Loc 0" }],
      "messages" => [],
      "system_messages" => [],
      "objects" => [],
      "connections" => [],
      "vocabulary" => [],
      "processes" => [],
      "defaults" => {},
    }
  end
  let(:engine) { PAWS::Engine.new(game_data, interface) }
  let(:registry) { PAWS::CondactRegistry.new }

  before do
    allow(interface).to receive(:set_colors)
    allow(interface).to receive(:colorize)
    described_class.register(registry, engine)
  end

  it "registers flag action handlers" do
    expect(registry.call("SET", [50])).to eq(:ok)
    expect(engine.state.get_flag(50)).to eq(255)

    expect(registry.call("CLEAR", [50])).to eq(:ok)
    expect(engine.state.get_flag(50)).to eq(0)

    expect(registry.call("LET", [50, 10])).to eq(:ok)
    expect(registry.call("PLUS", [50, 5])).to eq(:ok)
    expect(registry.call("MINUS", [50, 3])).to eq(:ok)
    expect(engine.state.get_flag(50)).to eq(12)

    expect(registry.call("COPYFF", [50, 51])).to eq(:ok)
    expect(engine.state.get_flag(51)).to eq(12)
  end

  it "registers flag condition handlers" do
    engine.state.set_flag(50, 10)
    engine.state.set_flag(51, 5)

    expect(registry.call("NOTZERO", [50])).to eq(:ok)
    expect(registry.call("ZERO", [60])).to eq(:ok)
    expect(registry.call("EQ", [50, 10])).to eq(:ok)
    expect(registry.call("NOTEQ", [50, 5])).to eq(:ok)
    expect(registry.call("GT", [50, 5])).to eq(:ok)
    expect(registry.call("LT", [51, 10])).to eq(:ok)
    expect(registry.call("SAME", [50, 50])).to eq(:ok)
    expect(registry.call("NOTSAME", [50, 51])).to eq(:ok)
    expect(registry.call("BIGGER", [50, 51])).to eq(:ok)
    expect(registry.call("SMALLER", [51, 50])).to eq(:ok)
  end
end
