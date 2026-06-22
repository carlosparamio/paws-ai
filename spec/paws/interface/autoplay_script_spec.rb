# frozen_string_literal: true

require "spec_helper"
require "paws/interface/autoplay_script"
require "tempfile"

RSpec.describe PAWS::AutoplayScript do
  def command_file(contents)
    Tempfile.new("paws-autoplay-script").tap do |file|
      file.write(contents)
      file.close
    end
  end

  it "loads all commands by default" do
    file = command_file("n\ns\ni\n")

    expect(described_class.load(file.path)).to eq(%w[n s i])
  ensure
    file&.close!
  end

  it "ignores blank and comment lines" do
    file = command_file("# wake title and verify OCR first\n\nn\n  ; random event guard\ns\n")

    expect(described_class.load(file.path)).to eq(%w[n s])
  ensure
    file&.close!
  end

  it "loads a 1-based inclusive line range" do
    file = command_file("# note\nn\ns\n; checkpoint\ni\nmirar\n")

    expect(described_class.load(file.path, range: "2-3")).to eq(%w[s i])
  ensure
    file&.close!
  end

  it "accepts all as an explicit range" do
    file = command_file("n\ns\n")

    expect(described_class.load(file.path, range: "all")).to eq(%w[n s])
  ensure
    file&.close!
  end

  it "splits a CLI path:range shorthand when the full path does not exist" do
    path, range = described_class.parse_cli_spec("commands.txt:4-9")

    expect(path).to eq("commands.txt")
    expect(range).to eq("4-9")
  end

  it "rejects invalid ranges" do
    file = command_file("n\n")

    expect { described_class.load(file.path, range: "3-2") }.to raise_error(PAWS::AutoplayScript::Error)
    expect { described_class.load(file.path, range: "bad") }.to raise_error(PAWS::AutoplayScript::Error)
  ensure
    file&.close!
  end
end
