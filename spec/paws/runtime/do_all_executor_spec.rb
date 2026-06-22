# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::DoAllExecutor do
  let(:state) do
    PAWS::GameState.new({
      "objects" => [
        { "initial_location" => 5 },
        { "initial_location" => 5 },
      ],
    })
  end
  let(:game_data) do
    {
      "objects" => [
        { "noun_id" => 10, "adjective_id" => 255 },
        { "noun_id" => 20, "adjective_id" => 7 },
      ],
    }
  end
  let(:engine) do
    instance_spy(
      PAWS::Engine,
      state: state,
      game_data: game_data,
      describe_flag: false,
    )
  end
  let(:execution_context) { PAWS::ProcessExecutionContext.new }
  let(:object_reference) { instance_spy(PAWS::ObjectReferenceState) }
  let(:process_control) { instance_spy(PAWS::ProcessControl, response_process?: false) }

  subject(:executor) do
    described_class.new(
      engine: engine,
      execution_context: execution_context,
      object_reference: object_reference,
      process_control: process_control,
    )
  end

  it "runs remaining condacts for each visible object at a location" do
    remaining = [{ "name" => "BEEP", "params" => [] }]

    expect(executor.call(5, remaining)).to eq(:ok)

    expect(process_control).to have_received(:run_condacts).with(remaining).twice
    expect(object_reference).to have_received(:update).with(0)
    expect(object_reference).to have_received(:update).with(1)
    expect(state.get_flag(PAWS::GameState::FLAG_NOUN1)).to eq(20)
    expect(state.get_flag(PAWS::GameState::FLAG_ADJECT1)).to eq(7)
  end

  it "re-runs response process 0 when there is no remaining body" do
    allow(process_control).to receive(:response_process?).and_return(true)

    expect(executor.call(5, [])).to eq(:ok)

    expect(process_control).to have_received(:run_process).with(0).twice
    expect(execution_context.done?).to be true
    expect(engine).to have_received(:set_done)
  end
end
