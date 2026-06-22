# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "bin/web CLI" do
  let(:web_path) { File.expand_path("../../bin/web", __dir__) }

  it "displays help message with --help" do
    stdout, _stderr, status = Open3.capture3("#{web_path} --help")

    expect(stdout).to include("Usage: web [options] <game_file.json|.sna|.z80|.sp>")
    expect(stdout).to include("-d, --debug")
    expect(stdout).to include("-P, --parser-mode")
    expect(stdout).to include("-g, --graphics-mode")
    expect(stdout).to include("-G, --graphics-cache")
    expect(stdout).to include("-S, --skip-clear-screen")
    expect(stdout).to include("-R, --record-commands")
    expect(stdout).to include("-T, --transcript")
    expect(stdout).to include("-a, --autoplay")
    expect(stdout).to include("--mapping")
    expect(stdout).to include("-r MODE[:FONT_SIZE]")
    expect(stdout).to include("--text-renderer")
    expect(stdout).not_to include("--font-size")
    expect(stdout).not_to include("--autoplay-range")
    expect(status.success?).to be true
  end

  it "fails when no game file is provided" do
    _stdout, stderr, status = Open3.capture3(web_path)

    expect(stderr).to include("Error: No game file specified.")
    expect(status.success?).to be false
  end

  it "fails when the game file does not exist" do
    _stdout, stderr, status = Open3.capture3("#{web_path} non_existent.json")

    expect(stderr).to include("Error: File not found: non_existent.json")
    expect(status.success?).to be false
  end
end
