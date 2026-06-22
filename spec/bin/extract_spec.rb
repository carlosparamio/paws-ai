# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "bin/extract CLI" do
  let(:extract_path) { File.expand_path("../../bin/extract", __dir__) }

  it "displays help message with --help" do
    stdout, _stderr, status = Open3.capture3("#{extract_path} --help")
    expect(stdout).to include("Usage:")
    expect(stdout).to include("--mapping")
    expect(stdout).to include("--generate-mapping")
    expect(stdout).to include("--translate-to")
    expect(stdout).to include("--translation-report")
    expect(stdout).to include("--translation-batch-chars")
    expect(status.success?).to be true
  end

  it "fails when no snapshot is provided" do
    _stdout, stderr, status = Open3.capture3(extract_path)
    expect(stderr).to include("Error: No SNA file specified")
    expect(status.success?).to be false
  end

  it "fails when snapshot file does not exist" do
    _stdout, stderr, status = Open3.capture3("#{extract_path} non_existent.sna")
    expect(stderr).to include("not found")
    expect(status.success?).to be false
  end

  it "requires an explicit mapping when translating" do
    fixture = File.expand_path("../../games/espia.sna", __dir__)

    _stdout, stderr, status = Open3.capture3("#{extract_path} --translate-to en #{fixture}")

    expect(stderr).to include("Translation requires an explicit character mapping")
    expect(status.success?).to be false
  end

  # We won't test a successful extraction here to avoid needing a valid
  # complex fixture, but we've verified the argument parsing logic.
end
