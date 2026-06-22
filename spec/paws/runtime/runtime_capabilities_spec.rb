# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/runtime_capabilities"

RSpec.describe PAWS::RuntimeCapabilities do
  subject(:capabilities) { described_class.cli }

  it "describes unsupported CLI runtime features" do
    reason = capabilities.unsupported_reason(:graphics_mode)

    expect(reason.feature).to eq(:graphics_mode)
    expect(reason).to be_unsupported
    expect(reason.to_s).to eq("graphics mode is unavailable in the Ruby CLI runtime")
  end

  it "describes intentional CLI no-op effects" do
    reason = capabilities.optional_noop_reason(:sound)

    expect(reason.feature).to eq(:sound)
    expect(reason).to be_optional_noop
    expect(reason.to_s).to eq("sound is optional in the CLI runtime")
  end
end
