# frozen_string_literal: true

require_relative "spec_helper"

module PAWS
  module TestSupport
    # Headless UI double that captures output and feeds scripted input.
    # Zero dependencies on TTY gems — pure Ruby for fast, isolated specs.
    class HeadlessUI < Interface
      attr_reader :output_lines

      def initialize
        @output_lines = []
        @input_queue = []
      end

      # Enqueue one or more commands to be consumed by Runtime#get_input.
      def queue_input(*commands)
        @input_queue.concat(commands)
        self
      end

      # --- Interface contract (consumed by Runtime) ---

      def get_input
        @input_queue.shift
      end

      def output_text(text, newline: true)
        @output_lines << PAWS::TextMarkup.render_glyph_tags(text)
      end

      def colorize(text, *_styles)
        text
      end

      def clear_screen; end
      def flush_input_buffer; end
      def stop; end
      def wait_for_key(_msg = nil) end
      def update_status(**_opts) end
      def set_colors(**_opts) end
    end

    # GameHarness wraps a full Engine stack for deterministic integration testing.
    #
    # Usage in specs:
    #   harness = PAWS::TestSupport::GameHarness.new("games/espia.json")
    #   harness.game_input("NORTE")
    #   expect(harness.get_flag(38)).to eq(4)
    #
    class GameHarness
      attr_reader :engine, :state, :ui, :game_data

      def initialize(json_path)
        @game_data = GameData::Serializer.load(json_path)
        raw_data = JSON.parse(File.read(json_path)) # Engine needs string keys
        @ui = HeadlessUI.new
        @engine = Engine.new(raw_data, @ui)
        @state = @engine.state
      end

      # ── Flag helpers ──────────────────────────────────────────────

      def get_flag(id)
        @state.get_flag(id)
      end

      def set_flag(id, value)
        @state.set_flag(id, value)
      end

      def active_flags
        @state.flags.each_with_index.each_with_object({}) do |(val, idx), memo|
          memo[idx] = val unless val.zero?
        end
      end

      # ── Command execution ─────────────────────────────────────────

      def game_input(command)
        @engine.send(:parse_input, command)
        verb = @engine.instance_variable_get(:@current_verb)

        unless verb
          @ui.output_lines << (@game_data[:system_messages][6] || "")
          return false
        end

        @engine.send(:store_parsed_words)
        @state.increment_turns

        @engine.instance_variable_set(:@done_flag, false)
        @engine.run_process(0)

        unless @engine.done_flag
          @engine.send(:try_direction_movement)
        end

        true
      end

      def run_events
        @engine.run_process(2)
      end

      def run_description_extras
        @engine.run_process(1)
      end

      # ── Output helpers ────────────────────────────────────────────

      def output
        @ui.output_lines
      end

      def full_output
        @ui.output_lines.join("\n")
      end

      def last_output
        @ui.output_lines.last
      end

      def clear_output
        @ui.output_lines.clear
      end

      # ── Object helpers ────────────────────────────────────────────

      def object_location(obj_id)
        @state.object_at(obj_id)
      end

      def player_location
        @state.location
      end
    end
  end
end

# ── RSpec convenience DSL ───────────────────────────────────────────
#
# Include in any spec file with:
#   require 'paws_helper'
#
# Then use inside examples:
#   let(:game) { load_espia }
#   it { game.game_input("N"); expect(game.get_flag(38)).to eq(4) }
#
module PAWSIntegrationHelpers
  GAME_DATA_DIR = File.expand_path("../games", __dir__).freeze

  # Load a game JSON by short name (defaults to the oracle: espia).
  def load_game(name = "espia")
    path = File.join(GAME_DATA_DIR, "#{name}.json")
    raise "Game data not found: #{path}" unless File.exist?(path)

    PAWS::TestSupport::GameHarness.new(path)
  end

  # Convenience alias for the primary oracle game.
  def load_espia
    load_game("espia")
  end
end

RSpec.configure do |config|
  config.include PAWSIntegrationHelpers, type: :integration
end
