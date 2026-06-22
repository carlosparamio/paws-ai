# frozen_string_literal: true

require "spec_helper"
require "paws/interface/save_game_store"

RSpec.describe PAWS::SaveGameStore do
  subject(:store) { described_class.new }

  let(:state) { instance_double(PAWS::GameState, to_json: '{"loc":1}') }

  it "normalizes save filenames and writes serialized state" do
    expect(File).to receive(:write).with("slot.sav", '{"loc":1}')

    store.save("slot", state)
  end

  it "loads JSON save data with symbol keys" do
    expect(File).to receive(:read).with("slot.sav").and_return('{"loc":1}')

    expect(store.load("slot")).to eq(loc: 1)
  end

  it "checks for normalized save filenames" do
    expect(File).to receive(:exist?).with("slot.sav").and_return(true)

    expect(store).to exist("slot")
  end
end
