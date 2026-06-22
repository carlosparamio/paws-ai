# frozen_string_literal: true

require "spec_helper"
require "paws/runtime/process_table_scanner"

RSpec.describe PAWS::ProcessTableScanner do
  let(:engine) do
    instance_double("Engine", verbosity: 0, running?: true, abort_execution: false)
  end

  let(:execution_context) do
    PAWS::ProcessExecutionContext.new.tap(&:push_frame)
  end

  let(:entry_matcher) { instance_double(PAWS::EntryMatcher) }
  let(:entry_index_stack) { [0] }
  let(:condact_index_stack) { [0] }
  let(:breakpoints) { [] }
  let(:executed_condacts) { [] }

  subject(:scanner) do
    described_class.new(
      engine: engine,
      execution_context: execution_context,
      entry_matcher: entry_matcher,
      entry_index_stack: entry_index_stack,
      condact_index_stack: condact_index_stack,
      check_breakpoint: -> { breakpoints << [entry_index_stack.last, condact_index_stack.last] },
      run_condacts: ->(condacts) { executed_condacts << condacts },
      debug_prefix: -> { "[P001|B001|C000]" },
    )
  end

  it "scans each entry, executes only matches, and updates debug coordinates" do
    entries = [
      { "match" => true, "condacts" => [{ "name" => "MESSAGE" }] },
      { "match" => false, "condacts" => [{ "name" => "DONE" }] },
      { "match" => true, "condacts" => [] },
    ]

    allow(entry_matcher).to receive(:matches?) { |entry, mode:| mode == :automatic && entry["match"] }

    scanner.call(entries, mode: :automatic)

    expect(executed_condacts).to eq([[{ "name" => "MESSAGE" }], []])
    expect(breakpoints).to eq([[1, 0], [2, 0], [3, 0]])
    expect(entry_index_stack.last).to eq(3)
    expect(condact_index_stack.last).to eq(0)
  end

  it "stops scanning after DONE is marked by an executed entry" do
    scanner = described_class.new(
      engine: engine,
      execution_context: execution_context,
      entry_matcher: entry_matcher,
      entry_index_stack: entry_index_stack,
      condact_index_stack: condact_index_stack,
      check_breakpoint: -> { breakpoints << [entry_index_stack.last, condact_index_stack.last] },
      run_condacts: lambda do |condacts|
        executed_condacts << condacts
        execution_context.mark_done
      end,
      debug_prefix: -> { "[P001|B001|C000]" },
    )

    entries = [
      { "match" => true, "condacts" => [{ "name" => "DONE" }] },
      { "match" => true, "condacts" => [{ "name" => "MESSAGE" }] },
    ]

    allow(entry_matcher).to receive(:matches?).and_return(true)

    scanner.call(entries, mode: :response)

    expect(executed_condacts).to eq([[{ "name" => "DONE" }]])
    expect(breakpoints).to eq([[1, 0]])
  end

  it "keeps scanning response entries after a PARSE-style reparse" do
    entries = [
      { "match" => true, "condacts" => [{ "name" => "PARSE" }] },
      { "match" => true, "condacts" => [{ "name" => "MESSAGE" }] },
    ]

    allow(entry_matcher).to receive(:matches?).and_return(true)

    scanner = described_class.new(
      engine: engine,
      execution_context: execution_context,
      entry_matcher: entry_matcher,
      entry_index_stack: entry_index_stack,
      condact_index_stack: condact_index_stack,
      check_breakpoint: -> { breakpoints << [entry_index_stack.last, condact_index_stack.last] },
      run_condacts: lambda do |condacts|
        executed_condacts << condacts
        condacts.first["name"] == "PARSE" ? :continue_scan : :ok
      end,
      debug_prefix: -> { "[P001|B001|C000]" },
    )

    scanner.call(entries, mode: :response)

    expect(executed_condacts).to eq([
      [{ "name" => "PARSE" }],
      [{ "name" => "MESSAGE" }],
    ])
  end
end
