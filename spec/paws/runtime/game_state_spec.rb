# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/game_state"

RSpec.describe PAWS::GameState do
  let(:game_data) do
    {
      "objects" => [
        { "initially_at" => 1, "weight" => 2, "attrs_lo" => 0, "attrs_hi" => 0 },
        { "initially_at" => 254, "weight" => 1, "attrs_lo" => 1, "attrs_hi" => 0 }, # carried
        { "initially_at" => 253, "weight" => 3, "attrs_lo" => 0, "attrs_hi" => 0 }, # worn
        { "initially_at" => 252, "weight" => 1, "attrs_lo" => 0, "attrs_hi" => 0 },  # not created
      ],
      "connections" => [
        [0, [[1, 2], [2, 3]]], # loc 0: dir 1->2, dir 2->3
        [1, [[1, 0]]],          # loc 1: dir 1->0
      ],
      "defaults" => { "max_carried" => 4, "max_weight" => 10 },
    }
  end

  subject(:state) { described_class.new(game_data) }

  describe "#initialize" do
    it "initializes 256 flags" do
      expect(state.flags.size).to eq(256)
      # Most flags are 0, but some have defaults (max_carried, objects_carried, etc.)
      expect(state.get_flag(50)).to eq(0) # arbitrary flag should be 0
    end

    it "loads object initial locations" do
      expect(state.object_at(0)).to eq(1)
      expect(state.object_at(1)).to eq(254) # carried
      expect(state.object_at(2)).to eq(253) # worn
      expect(state.object_at(3)).to eq(252) # not created
    end

    it "counts initially carried objects" do
      expect(state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(1)
    end

    it "loads connections" do
      expect(state.connection(0, 1)).to eq(2)
      expect(state.connection(0, 2)).to eq(3)
      expect(state.connection(1, 1)).to eq(0)
    end
  end

  describe "flag operations" do
    it "#get_flag returns flag value" do
      state.set_flag(10, 42)
      expect(state.get_flag(10)).to eq(42)
    end

    it "#set_flag wraps at 255" do
      state.set_flag(10, 300)
      expect(state.get_flag(10)).to eq(44) # 300 & 0xFF
    end

    it "#location reads/writes flag 38" do
      state.location = 5
      expect(state.location).to eq(5)
      expect(state.get_flag(38)).to eq(5)
    end

    it "#dark? checks flag 0" do
      expect(state.dark?).to be false
      state.set_flag(0, 1)
      expect(state.dark?).to be true
    end

    it "#turns combines flags 31 and 32" do
      state.set_flag(31, 0x34)
      state.set_flag(32, 0x12)
      expect(state.turns).to eq(0x1234)
    end

    it "#increment_turns handles overflow" do
      state.set_flag(31, 255)
      state.set_flag(32, 0)
      state.increment_turns
      expect(state.get_flag(31)).to eq(0)
      expect(state.get_flag(32)).to eq(1)
    end
  end

  describe "object operations" do
    it "#object_carried? returns true for loc 254" do
      expect(state.object_carried?(1)).to be true
      expect(state.object_carried?(0)).to be false
    end

    it "#object_worn? returns true for loc 253" do
      expect(state.object_worn?(2)).to be true
      expect(state.object_worn?(0)).to be false
    end

    it "#object_here? checks current location" do
      state.location = 1
      expect(state.object_here?(0)).to be true
      expect(state.object_here?(1)).to be false
    end

    it "#object_present? checks carried, worn, or here" do
      state.location = 1
      expect(state.object_present?(0)).to be true  # here
      expect(state.object_present?(1)).to be true  # carried
      expect(state.object_present?(2)).to be true  # worn
      expect(state.object_present?(3)).to be false # not created
    end

    it "#set_object_location updates carried count" do
      initial = state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)
      state.set_object_location(0, 254) # pick up
      expect(state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(initial + 1)

      state.set_object_location(0, 1) # drop
      expect(state.get_flag(PAWS::GameState::FLAG_OBJECTS_CARRIED)).to eq(initial)
    end

    it "#objects_at returns objects at location" do
      expect(state.objects_at(1)).to eq([0])
      expect(state.objects_at(254)).to eq([1])
    end

    it "#carried_objects returns carried objects" do
      expect(state.carried_objects).to eq([1])
    end

    it "#worn_objects returns worn objects" do
      expect(state.worn_objects).to eq([2])
    end

    it "#total_carried_weight sums carried and worn" do
      # obj 1 (carried, weight 1) + obj 2 (worn, weight 3)
      expect(state.total_carried_weight).to eq(4)
    end
  end

  describe "object attributes" do
    it "#object_attr? checks attribute bit" do
      state.set_object_attr(0, 0, true)
      expect(state.object_attr?(0, 0)).to be true
      expect(state.object_attr?(0, 1)).to be false
    end

    it "#set_object_attr sets/clears bits" do
      state.set_object_attr(0, 5, true)
      expect(state.object_attr?(0, 5)).to be true
      state.set_object_attr(0, 5, false)
      expect(state.object_attr?(0, 5)).to be false
    end
  end

  describe "serialization" do
    it "#ramsave/#ramload preserves state" do
      state.location = 10
      state.set_flag(50, 123)
      state.set_object_location(0, 5)

      state.ramsave

      state.location = 0
      state.set_flag(50, 0)
      state.set_object_location(0, 1)

      expect(state.ramload).to be true
      expect(state.location).to eq(10)
      expect(state.get_flag(50)).to eq(123)
      expect(state.object_at(0)).to eq(5)
    end

    it "#ramload returns false if no save" do
      expect(state.ramload).to be false
    end

    it "#serialize/#deserialize round-trips" do
      state.location = 15
      state.set_flag(100, 200)

      data = state.serialize
      state.location = 0
      state.set_flag(100, 0)

      state.deserialize(data)
      expect(state.location).to eq(15)
      expect(state.get_flag(100)).to eq(200)
    end
  end

  describe "#reset!" do
    it "restores initial state" do
      state.location = 99
      state.set_flag(50, 123)
      state.set_object_location(0, 254)

      state.reset!

      expect(state.location).to eq(0)
      expect(state.get_flag(50)).to eq(0)
      expect(state.object_at(0)).to eq(1) # initial location
    end
  end

  describe "extra coverage cases" do
    it "covers high attribute bits" do
      state.set_object_attr(0, 35, true)
      expect(state.object_attr?(0, 35)).to be true
      state.set_object_attr(0, 35, false)
      expect(state.object_attr?(0, 35)).to be false
    end

    it "covers set_connection" do
      state.set_connection(5, 1, 10)
      expect(state.connection(5, 1)).to eq(10)
    end

    it "covers JSON serialization/deserialization" do
      state.location = 12
      json = state.to_json
      new_state = described_class.from_json(json, game_data)
      expect(new_state.location).to eq(12)
    end

    it "covers deep_dup with arrays" do
      arr = [1, [2, 3]]
      expect(state.send(:deep_dup, arr)).to eq([1, [2, 3]])
    end

    it "covers object_absent?, objects, and listable_objects_at" do
      expect(state.object_absent?(0)).to be true
      expect(state.objects.to_a).to be_an(Array)
      state.set_object_location(0, 5)
      expect(state.listable_objects_at(5)).to include(0)
    end
  end
end
