# frozen_string_literal: true

require "paws_helper"

RSpec.describe "Integration Helpers", type: :integration do
  # ── Loading ───────────────────────────────────────────────────────

  describe "load_game / load_espia" do
    it "loads El Espía from games/espia.json" do
      game = load_espia
      expect(game).to be_a(PAWS::TestSupport::GameHarness)
    end

    it "exposes game_data with all required keys" do
      game = load_espia
      %i[vocabulary locations messages system_messages objects processes].each do |key|
        expect(game.game_data).to have_key(key), "missing key: #{key}"
      end
    end

    it "raises when game data file is missing" do
      expect { load_game("nonexistent") }.to raise_error(/Game data not found/)
    end
  end

  # ── Flag reading ──────────────────────────────────────────────────

  describe "#get_flag / #set_flag" do
    let(:game) { load_espia }

    it "reads initial flag 37 (max objects carryable) as 4" do
      expect(game.get_flag(37)).to eq(4)
    end

    it "reads initial flag 38 (current location)" do
      expect(game.get_flag(38)).to eq(game.player_location)
    end

    it "writes and reads back a flag value" do
      game.set_flag(60, 42)
      expect(game.get_flag(60)).to eq(42)
    end

    it "clamps flag values to 0-255 range" do
      game.set_flag(60, 300)
      expect(game.get_flag(60)).to be_between(0, 255)
    end
  end

  # ── Active flags snapshot ─────────────────────────────────────────

  describe "#active_flags" do
    let(:game) { load_espia }

    it "returns only non-zero flags as a Hash" do
      flags = game.active_flags
      expect(flags).to be_a(Hash)
      expect(flags.values).to all(be > 0)
    end

    it "includes flag 37 (max carry) in the snapshot" do
      expect(game.active_flags).to include(37 => 4)
    end
  end

  # ── Command execution ────────────────────────────────────────────

  describe "#game_input" do
    let(:game) { load_espia }

    it "increments the turn counter (flags 31/32)" do
      initial_turns = game.get_flag(31)
      game.game_input("MIRAR")
      expect(game.get_flag(31)).to eq(initial_turns + 1)
    end

    it "sets verb in LS flag 33 after parsing" do
      game.game_input("MIRAR")
      expect(game.get_flag(33)).to be > 0
    end

    it "returns false for unparseable input" do
      result = game.game_input("XYZZYPLUGH")
      expect(result).to be false
    end

    it "emits SM6 (no entiendo) for unparseable input" do
      game.game_input("XYZZYPLUGH")
      expect(game.full_output).to include(game.game_data[:system_messages][6])
    end
  end

  # ── Output capture ───────────────────────────────────────────────

  describe "output helpers" do
    let(:game) { load_espia }

    it "captures engine output lines" do
      game.game_input("MIRAR")
      expect(game.output).to be_an(Array)
    end

    it "clears output on demand" do
      game.game_input("MIRAR")
      game.clear_output
      expect(game.output).to be_empty
    end

    it "joins output into full_output string" do
      game.game_input("INVENTARIO")
      expect(game.full_output).to be_a(String)
    end
  end

  # ── HeadlessUI contract ──────────────────────────────────────────

  describe PAWS::TestSupport::HeadlessUI do
    subject(:ui) { described_class.new }

    it "captures output_text calls" do
      ui.output_text("Hello")
      ui.output_text("World")
      expect(ui.output_lines).to eq(%w[Hello World])
    end

    it "feeds queued input in FIFO order" do
      ui.queue_input("A", "B", "C")
      expect(ui.get_input).to eq("A")
      expect(ui.get_input).to eq("B")
      expect(ui.get_input).to eq("C")
    end

    it "returns nil when input queue is exhausted" do
      expect(ui.get_input).to be_nil
    end

    it "responds to all Runtime UI methods without error" do
      expect { ui.clear_screen }.not_to raise_error
      expect { ui.stop }.not_to raise_error
      expect { ui.wait_for_key("press") }.not_to raise_error
      expect { ui.update_status(location: "test") }.not_to raise_error
      expect { ui.set_colors(ink: "white") }.not_to raise_error
    end
  end
end
