# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::CondactHandlers::ObjectAutoActions do
  let(:registry) { PAWS::CondactRegistry.new }
  let(:game_data) do
    {
      "objects" => [
        { "initial_location" => 252, "noun_id" => 1, "adjective_id" => 255 },
        { "initial_location" => 252, "noun_id" => 2, "adjective_id" => 255 },
        { "initial_location" => 252, "noun_id" => 3, "adjective_id" => 255 },
        { "initial_location" => 1, "noun_id" => 10, "adjective_id" => 255 },
      ],
    }
  end
  let(:state) { PAWS::GameState.new(game_data) }
  let(:engine) { instance_double(PAWS::Engine, state: state, game_data: game_data) }
  let(:calls) { [] }

  before do
    registry.register("WHATO") { calls << :whato; :ok }
    registry.register("GET") { |objno| calls << [:get, objno]; :ok }
    registry.register("DROP") { |objno| calls << [:drop, objno]; :ok }
    registry.register("WEAR") { |objno| calls << [:wear, objno]; :ok }
    registry.register("REMOVE") { |objno| calls << [:remove, objno]; :ok }
    registry.register("PUTIN") { |objno, locno| calls << [:putin, objno, locno]; :ok }
    registry.register("TAKEOUT") { |objno, locno| calls << [:takeout, objno, locno]; :ok }
    described_class.register(registry, engine)
    state.location = 1
    state.set_flag(PAWS::GameState::FLAG_NOUN1, 10)
    state.set_flag(PAWS::GameState::FLAG_ADJECT1, 255)
  end

  it "delegates AUTOG/AUTOD/AUTOW/AUTOR to the object resolved from the current noun" do
    expect(registry.call("AUTOG")).to eq(:ok)
    expect(registry.call("AUTOD")).to eq(:ok)
    expect(registry.call("AUTOW")).to eq(:ok)
    expect(registry.call("AUTOR")).to eq(:ok)

    expect(calls).to eq([
      [:get, 3],
      [:drop, 3],
      [:wear, 3],
      [:remove, 3],
    ])
  end

  it "delegates AUTOP/AUTOT with container locations and the object resolved from the current noun" do
    expect(registry.call("AUTOP", [8])).to eq(:ok)
    expect(registry.call("AUTOT", [9])).to eq(:ok)

    expect(calls).to eq([
      [:putin, 3, 8],
      [:takeout, 3, 9],
    ])
  end
end
