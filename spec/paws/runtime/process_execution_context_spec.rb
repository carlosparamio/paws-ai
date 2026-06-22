# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::ProcessExecutionContext do
  subject(:context) { described_class.new }

  it "tracks DONE state per process frame" do
    context.push_frame
    expect(context.done?).to be false

    context.mark_done
    expect(context.done?).to be true

    context.mark_notdone
    expect(context.done?).to be false
    expect(context.pop_frame).to be false
  end

  it "creates an implicit frame for direct handler dispatch" do
    context.mark_done

    expect(context.done?).to be true
    expect(context.done_stack.size).to eq(1)
  end

  it "tracks DOALL abort requests separately from DONE state" do
    expect(context.abort_doall?).to be false

    context.abort_doall!
    expect(context.abort_doall?).to be true

    context.reset_doall_abort
    expect(context.abort_doall?).to be false
  end
end
