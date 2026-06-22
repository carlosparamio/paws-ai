# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/engine_phases/turn_loop"

RSpec.describe PAWS::TurnLoop do
  let(:engine) do
    instance_double(
      PAWS::Engine,
      describe_flag: false,
      done_flag: false,
      :done_flag= => nil,
      running?: true,
      consume_restart_request: false,
      description_phase: nil,
      order_loop: nil,
      run_process: nil,
      input_phase: :found,
      response_phase: nil,
      output_sysmess: nil,
    )
  end

  subject(:loop_phase) { described_class.new(engine) }

  describe "#call" do
    it "describes before entering the order loop when requested" do
      allow(engine).to receive(:describe_flag).and_return(true)

      expect(engine).to receive(:description_phase).ordered
      expect(engine).to receive(:order_loop).ordered

      loop_phase.call
    end

    it "skips the description phase when no description is pending" do
      expect(engine).not_to receive(:description_phase)
      expect(engine).to receive(:order_loop)

      loop_phase.call
    end

    it "does not enter the order loop when description triggered a restart" do
      allow(engine).to receive(:describe_flag).and_return(true)
      allow(engine).to receive(:consume_restart_request).and_return(true)

      expect(engine).to receive(:description_phase)
      expect(engine).not_to receive(:order_loop)

      loop_phase.call
    end
  end

  describe "#order_loop" do
    it "runs process 2, input, and response in order" do
      expect(engine).to receive(:done_flag=).with(false).ordered
      expect(engine).to receive(:run_process).with(2, mode: :automatic).ordered
      expect(engine).to receive(:input_phase).ordered.and_return(:found)
      expect(engine).to receive(:response_phase).ordered

      loop_phase.order_loop
    end

    it "outputs timeout and unknown-input messages without responding" do
      allow(engine).to receive(:input_phase).and_return(:timeout, :not_found)

      expect(engine).to receive(:output_sysmess).with(35, newline: true)
      expect(engine).to receive(:output_sysmess).with(6, newline: true)
      expect(engine).not_to receive(:response_phase)

      loop_phase.order_loop
      loop_phase.order_loop
    end

    it "stops the current turn when process 2 triggered a restart" do
      allow(engine).to receive(:consume_restart_request).and_return(true)

      expect(engine).to receive(:done_flag=).with(false)
      expect(engine).to receive(:run_process).with(2, mode: :automatic)
      expect(engine).not_to receive(:input_phase)

      loop_phase.order_loop
    end
  end
end
