# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/state/object_store"

RSpec.describe PAWS::ObjectStore do
  subject(:store) do
    described_class.new(game_data, not_created_location: 252, on_change: change_callback)
  end

  let(:changes) { [] }
  let(:change_callback) { ->(object, location) { changes << [object, location] } }
  let(:game_data) do
    {
      "objects" => [
        { "initial_location" => 1, "weight" => 2, "attrs_lo" => 0, "attrs_hi" => 0 },
        { "initial_location" => 254, "weight" => 1, "attrs_lo" => 1, "attrs_hi" => 0 },
        { "initially_at" => 253, "weight" => 3, "attrs_lo" => 0, "attrs_hi" => 0 },
        { "weight" => 1, "is_container" => true, "is_wearable" => true },
      ],
    }
  end

  it "loads object locations and attributes from PAWS object data" do
    expect(store.locations).to eq([1, 254, 253, 252])
    expect(store.attrs_lo).to eq([0, 1, 0, (1 << 14) | (1 << 15)])
    expect(store.attrs_hi).to eq([0, 0, 0, 0])
  end

  it "moves objects and reports changes" do
    expect(store.move(0, 5)).to eq([1, 5])
    expect(store.at(0)).to eq(5)
    expect(changes).to eq([[0, 5]])
  end

  it "answers inventory and presence queries" do
    expect(store.carried?(1, carried_location: 254)).to be true
    expect(store.worn?(2, worn_location: 253)).to be true
    expect(store.here?(0, current_location: 1)).to be true
    expect(store.present?(0, current_location: 1, carried_location: 254, worn_location: 253)).to be true
  end

  it "finds objects by location and hides concealed objects from listable results" do
    store.set_attr(0, 10, true)

    expect(store.at_location(1)).to eq([0])
    expect(store.listable_at(1)).to be_empty
  end

  it "handles low and high attribute bits" do
    store.set_attr(0, 5, true)
    store.set_attr(0, 35, true)

    expect(store.attr?(0, 5)).to be true
    expect(store.attr?(0, 35)).to be true
  end

  it "calculates object weights" do
    expect(store.weight(0)).to eq(2)
    expect(store.total_weight([0, 2])).to eq(5)
  end

  it "replaces serialized tables without reporting changes" do
    store.replace(locations: [9], attrs_lo: [2], attrs_hi: [4])

    expect(store.locations).to eq([9])
    expect(store.attrs_lo).to eq([2])
    expect(store.attrs_hi).to eq([4])
    expect(changes).to be_empty
  end
end
