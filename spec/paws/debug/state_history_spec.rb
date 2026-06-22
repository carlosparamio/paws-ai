# frozen_string_literal: true

require "spec_helper"
require "paws/debug/state_history"

RSpec.describe PAWS::StateHistory do
  subject(:history) { described_class.new(capacity: 3) }

  it "initializes with capacity" do
    expect(history.capacity).to eq(3)
    expect(history).to be_empty
    expect(history.size).to eq(0)
  end

  it "enforces a minimum capacity of 1" do
    sh = described_class.new(capacity: 0)
    expect(sh.capacity).to eq(1)

    sh2 = described_class.new(capacity: -5)
    expect(sh2.capacity).to eq(1)
  end

  it "records and retrieves snapshots" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    expect(history.size).to eq(1)
    expect(history).not_to be_empty

    entry = history.latest
    expect(entry.turn).to eq(1)
    expect(entry.location).to eq(4)
    expect(entry.input).to eq("n")
    expect(entry.snapshot).to eq({ f: 1 })
    expect(entry.timestamp).to be_a(Time)
  end

  it "returns a duplicate of entries list for safety" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    list = history.entries
    expect(list.size).to eq(1)
    list << "corrupt"
    expect(history.size).to eq(1)
  end

  it "discards the oldest snapshot when capacity is exceeded" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    history.push(turn: 2, location: 5, input: "e", snapshot: { f: 2 })
    history.push(turn: 3, location: 6, input: "s", snapshot: { f: 3 })
    expect(history.size).to eq(3)
    expect(history[0].turn).to eq(1)

    # Push 4th entry, turn 1 should be shifted out
    history.push(turn: 4, location: 7, input: "w", snapshot: { f: 4 })
    expect(history.size).to eq(3)
    expect(history[0].turn).to eq(2)
    expect(history[1].turn).to eq(3)
    expect(history[2].turn).to eq(4)
  end

  it "supports finding a snapshot at a specific turn" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    history.push(turn: 2, location: 5, input: "e", snapshot: { f: 2 })

    entry = history.at_turn(2)
    expect(entry).not_to be_nil
    expect(entry.turn).to eq(2)

    expect(history.at_turn(99)).to be_nil
  end

  it "allows retrieving entries back N steps from latest" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    history.push(turn: 2, location: 5, input: "e", snapshot: { f: 2 })
    history.push(turn: 3, location: 6, input: "s", snapshot: { f: 3 })

    # back(0) is latest (turn 3)
    expect(history.back(0).turn).to eq(3)
    # back(1) is previous (turn 2)
    expect(history.back(1).turn).to eq(2)
    # back(2) is oldest (turn 1)
    expect(history.back(2).turn).to eq(1)
    # back(3) exceeds history size
    expect(history.back(3)).to be_nil
  end

  it "can truncate entries after a specific index" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    history.push(turn: 2, location: 5, input: "e", snapshot: { f: 2 })
    history.push(turn: 3, location: 6, input: "s", snapshot: { f: 3 })
    expect(history.size).to eq(3)

    # Truncate after index 1 (turn 2), discarding index 2 (turn 3)
    history.truncate_after(1)
    expect(history.size).to eq(2)
    expect(history[0].turn).to eq(1)
    expect(history[1].turn).to eq(2)

    # Calling with out of bounds index is a no-op
    history.truncate_after(-1)
    expect(history.size).to eq(2)

    history.truncate_after(99)
    expect(history.size).to eq(2)
  end

  it "can be cleared" do
    history.push(turn: 1, location: 4, input: "n", snapshot: { f: 1 })
    history.clear
    expect(history).to be_empty
    expect(history.size).to eq(0)
  end
end
