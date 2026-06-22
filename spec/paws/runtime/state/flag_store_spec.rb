# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/state/flag_store"

RSpec.describe PAWS::FlagStore do
  subject(:store) { described_class.new(on_change: change_callback) }

  let(:changes) { [] }
  let(:change_callback) { ->(flag, old_value, new_value) { changes << [flag, old_value, new_value] } }

  it "initializes the PAWS flag table to 256 zeroed bytes" do
    expect(store.values.size).to eq(256)
    expect(store.get(10)).to eq(0)
  end

  it "wraps assigned values to one byte and reports changes" do
    store.set(10, 300)

    expect(store.get(10)).to eq(44)
    expect(changes).to eq([[10, 0, 44]])
  end

  it "does not report unchanged values" do
    store.set(10, 0)

    expect(changes).to be_empty
  end

  it "reloads flags only up to the requested RAMLOAD limit" do
    store.set(1, 10)
    store.set(2, 20)
    changes.clear

    store.reload_until([7, 8, 9], flag_limit: 1)

    expect(store.get(0)).to eq(7)
    expect(store.get(1)).to eq(8)
    expect(store.get(2)).to eq(20)
    expect(changes).to be_empty
  end
end
