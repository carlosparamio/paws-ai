# frozen_string_literal: true

require "spec_helper"
require "paws/debug/debug_command_parser"

RSpec.describe PAWS::DebugCommandParser do
  subject(:parser) { described_class.new }

  it "normalizes and tokenizes debugger input" do
    command = parser.parse("  B DEL 2  ")

    expect(command.raw).to eq("B DEL 2")
    expect(command.normalized).to eq("b del 2")
    expect(command.parts).to eq(%w[b del 2])
    expect(command.base).to eq("b")
    expect(command.arg).to eq("del")
  end

  it "represents empty input explicitly" do
    command = parser.parse(nil)

    expect(command).to be_empty
    expect(command.base).to be_nil
  end
end
