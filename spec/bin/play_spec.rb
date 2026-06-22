# frozen_string_literal: true

require "spec_helper"
require "open3"

RSpec.describe "bin/play CLI" do
  let(:play_path) { File.expand_path("../../bin/play", __dir__) }

  it "displays help message with shared short options" do
    stdout, _stderr, status = Open3.capture3("#{play_path} --help")

    expect(stdout).to include("Usage: play [options] <game_file.json|.sna>")
    expect(stdout).to include("-S, --skip-clear-screen")
    expect(stdout).to include("-B, --breakpoints-file")
    expect(stdout).to include("-F, --flags-desc-file")
    expect(stdout).to include("-P, --parser-mode")
    expect(stdout).to include("-d, --debug")
    expect(stdout).to include("-H, --history-size")
    expect(stdout).to include("-R, --record-commands")
    expect(stdout).to include("-T, --transcript")
    expect(stdout).to include("-a, --autoplay")
    expect(stdout).to include("-m, --mapping")
    expect(stdout).not_to include("--autoplay-range")
    expect(status.success?).to be true
  end
end
