# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/execution_result"

RSpec.describe PAWS::ExecutionResult do
  it "normalizes status values at runtime boundaries" do
    expect(described_class.from(:ok)).to be_ok
    expect(described_class.from([:failed, "reason"])).to have_attributes(
      status: :failed,
      details: "reason",
    )
  end

  it "exposes semantic predicates and tuple conversion for diagnostics" do
    result = described_class.failed("actual value is 9")

    expect(result).to be_failed
    expect(result).not_to be_abort
    expect(result.to_a).to eq([:failed, "actual value is 9"])
  end

  it "keeps equality readable for direct status assertions" do
    expect(described_class.unsupported).to eq(described_class.unsupported)
    expect(described_class.failed("no connection")).to eq(described_class.failed("no connection"))
  end

  it "rejects unknown statuses" do
    expect { described_class.new(:mystery) }.to raise_error(ArgumentError)
  end
end
