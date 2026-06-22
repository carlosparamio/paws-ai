# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine_phases/movement_fallback"

RSpec.describe PAWS::MovementFallback do
  class MovementFallbackState
    attr_accessor :location

    def initialize
      @flags = {}
      @connections = {}
      @location = 1
    end

    def set_flag(flag, value)
      @flags[flag] = value
    end

    def get_flag(flag)
      @flags.fetch(flag, 255)
    end

    def connect(from, verb, to)
      @connections[[from, verb]] = to
    end

    def connection(from, verb)
      @connections[[from, verb]]
    end
  end

  let(:state) { MovementFallbackState.new }
  let(:engine) do
    double(
      "Engine",
      state: state,
      :describe_flag= => nil,
      :done_flag= => nil,
      output_sysmess: nil,
    )
  end

  subject(:fallback) { described_class.new(engine) }

  it "moves through a direction connection and marks the turn done" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 1)
    state.connect(1, 1, 2)

    expect(engine).to receive(:describe_flag=).with(true)
    expect(engine).to receive(:done_flag=).with(true)

    expect(fallback.fallback_response).to eq(:moved)
    expect(state.location).to eq(2)
  end

  it "emits SM7 when a direction has no connection" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 2)

    expect(engine).to receive(:output_sysmess).with(7, newline: true)
    expect(engine).to receive(:done_flag=).with(true)

    expect(fallback.fallback_response).to eq(:failed)
    expect(state.location).to eq(1)
  end

  it "emits SM8 for non-direction verbs" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 99)

    expect(engine).to receive(:output_sysmess).with(8, newline: true)
    expect(engine).to receive(:done_flag=).with(true)

    expect(fallback.fallback_response).to eq(:failed)
  end

  it "supports silent movement checks for harnesses and pacing tests" do
    state.set_flag(PAWS::GameState::FLAG_VERB, 1)
    state.connect(1, 1, 2)

    expect(engine).to receive(:describe_flag=).with(true)
    expect(engine).not_to receive(:done_flag=)
    expect(engine).not_to receive(:output_sysmess)

    expect(fallback.try_direction_movement).to eq(:moved)
    expect(state.location).to eq(2)
  end
end
