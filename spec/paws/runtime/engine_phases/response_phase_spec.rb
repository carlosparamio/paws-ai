# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine_phases/response_phase"

RSpec.describe PAWS::ResponsePhase do
  let(:state) { instance_double(PAWS::GameState, increment_turns: nil) }

  let(:engine) do
    instance_double(
      PAWS::Engine,
      state: state,
      done_flag: false,
      :done_flag= => nil,
      running?: true,
      run_process: nil,
      fallback_response: nil,
    )
  end

  subject(:phase) { described_class.new(engine) }

  it "runs response process 0 before movement fallback" do
    expect(state).to receive(:increment_turns).ordered
    expect(engine).to receive(:done_flag=).with(false).ordered
    expect(engine).to receive(:run_process).with(0, mode: :response).ordered
    expect(engine).to receive(:fallback_response).ordered

    phase.call
  end

  it "skips fallback when process 0 marks the command done" do
    allow(engine).to receive(:run_process) do
      allow(engine).to receive(:done_flag).and_return(true)
    end

    expect(engine).not_to receive(:fallback_response)

    phase.call
  end
end
