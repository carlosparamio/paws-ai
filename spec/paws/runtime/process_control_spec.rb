# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::ProcessControl do
  it "delegates nested process execution to the runner public API" do
    runner = instance_spy(PAWS::ProcessRunner)
    control = described_class.new(runner)

    control.run_process(3)

    expect(runner).to have_received(:run_process).with(3)
  end

  it "delegates condact continuation to the runner public API" do
    runner = instance_spy(PAWS::ProcessRunner)
    control = described_class.new(runner)
    condacts = [{ "name" => "BEEP" }]

    control.run_condacts(condacts)

    expect(runner).to have_received(:run_condacts).with(condacts)
  end

  it "reports whether the current stack started in response process 0" do
    runner = instance_double(PAWS::ProcessRunner, process_stack: [0, 3])
    control = described_class.new(runner)

    expect(control.response_process?).to be true
  end
end
