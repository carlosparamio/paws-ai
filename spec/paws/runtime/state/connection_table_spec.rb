# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/state/connection_table"

RSpec.describe PAWS::ConnectionTable do
  subject(:table) { described_class.new(game_data) }

  let(:game_data) do
    {
      "connections" => [
        [0, [[1, 2], [2, 3]]],
        [1, [[1, 0]]],
      ],
    }
  end

  it "normalizes extracted PAWS connection pairs into a nested hash" do
    expect(table.values).to eq(0 => { 1 => 2, 2 => 3 }, 1 => { 1 => 0 })
  end

  it "returns destinations by location and direction" do
    expect(table.get(0, 1)).to eq(2)
    expect(table.get(0, 9)).to be_nil
  end

  it "sets dynamic exits" do
    table.set(5, 1, 10)

    expect(table.get(5, 1)).to eq(10)
  end

  it "replaces serialized connection state defensively" do
    serialized = { 9 => { 1 => 2 } }
    table.replace(serialized)
    serialized[9][1] = 7

    expect(table.get(9, 1)).to eq(2)
  end
end
