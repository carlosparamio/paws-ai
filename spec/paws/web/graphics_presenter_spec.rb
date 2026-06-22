# frozen_string_literal: true

require "spec_helper"
require "paws/web/graphics_presenter"

RSpec.describe PAWS::Web::GraphicsPresenter do
  StubRenderResult = Struct.new(
    :pixels,
    :attributes,
    :commands_seen,
    :commands_rendered,
    :commands_skipped,
    :pixels_set,
    keyword_init: true,
  )

  class StubGraphicsRenderer
    attr_reader :calls

    def initialize(result: nil)
      @calls = []
      @result = result
    end

    def render(commands, initial_attribute:, screen_attribute:, base_pixels: nil, base_attributes: nil)
      @calls << {
        commands: commands,
        initial_attribute: initial_attribute,
        screen_attribute: screen_attribute,
        base_pixels: base_pixels,
        base_attributes: base_attributes,
      }
      return @result if @result

      StubRenderResult.new(
        pixels: Array.new(192) { Array.new(256, false) },
        attributes: Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false, "flash" => false } } },
        commands_seen: 0,
        commands_rendered: 0,
        commands_skipped: 0,
        pixels_set: 0,
      )
    end
  end

  it "uses PAW v1 display defaults as the initial draw attribute" do
    renderer = StubGraphicsRenderer.new
    game_data = {
      "game" => { "paw_version" => 1 },
      "defaults" => { "ink" => 9, "paper" => 0 },
      "pictures" => {
        "entries" => [
          { "id" => 2, "ink" => 3, "paper" => 5, "decoded_commands" => [] },
        ],
      },
    }

    described_class.new(game_data, renderer: renderer).frame_for_picture(2)

    expect(renderer.calls.last.fetch(:initial_attribute)).to eq("ink" => 7, "paper" => 0)
    expect(renderer.calls.last.fetch(:screen_attribute)).to eq("ink" => 7, "paper" => 0)
  end

  it "keeps PAW v2 picture flags as the initial draw attribute" do
    renderer = StubGraphicsRenderer.new
    game_data = {
      "game" => { "paw_version" => 2 },
      "defaults" => { "ink" => 4, "paper" => 0 },
      "pictures" => {
        "entries" => [
          { "id" => 0, "ink" => 7, "paper" => 0, "decoded_commands" => [] },
        ],
      },
    }

    described_class.new(game_data, renderer: renderer).frame_for_picture(0)

    expect(renderer.calls.last.fetch(:initial_attribute)).to eq("ink" => 7, "paper" => 0)
  end

  it "passes the previous render result as a composition base" do
    renderer = StubGraphicsRenderer.new
    game_data = {
      "game" => { "paw_version" => 1 },
      "defaults" => { "ink" => 7, "paper" => 0 },
      "pictures" => {
        "entries" => [
          { "id" => 1, "decoded_commands" => [] },
          { "id" => 2, "decoded_commands" => [] },
        ],
      },
    }

    presenter = described_class.new(game_data, renderer: renderer)
    first = presenter.render_picture(1)
    presenter.render_picture(2, base_result: first.render_result)

    expect(renderer.calls.last.fetch(:base_pixels)).to be(first.render_result.pixels)
    expect(renderer.calls.last.fetch(:base_attributes)).to be(first.render_result.attributes)
  end

  it "marks pixels cleared relative to the composition base" do
    base_pixels = Array.new(192) { Array.new(256, false) }
    base_pixels[35][176] = true
    pixels = base_pixels.map(&:dup)
    pixels[35][176] = false
    result = StubRenderResult.new(
      pixels: pixels,
      attributes: Array.new(24) { Array.new(32) { { "ink" => 7, "paper" => 0, "bright" => false, "flash" => false } } },
      commands_seen: 1,
      commands_rendered: 1,
      commands_skipped: 0,
      pixels_set: 0,
    )
    base_result = StubRenderResult.new(
      pixels: base_pixels,
      attributes: result.attributes,
      commands_seen: 0,
      commands_rendered: 0,
      commands_skipped: 0,
      pixels_set: 1,
    )
    renderer = StubGraphicsRenderer.new(result: result)
    game_data = {
      "game" => { "paw_version" => 1 },
      "defaults" => { "ink" => 7, "paper" => 0 },
      "pictures" => {
        "entries" => [
          { "id" => 6, "decoded_commands" => [] },
        ],
      },
    }

    frame = described_class.new(game_data, renderer: renderer).render_picture(6, base_result: base_result).frame

    expect(frame.fetch("clear_rows")[35][176]).to eq("1")
  end

  it "marks PAW OVER line pixels as toggle rows" do
    game_data = {
      "game" => { "paw_version" => 1 },
      "defaults" => { "ink" => 7, "paper" => 0 },
      "pictures" => {
        "entries" => [
          {
            "id" => 6,
            "decoded_commands" => [
              {
                "family" => 1,
                "opcode" => 0x09,
                "point_before" => { "x" => 10, "y" => 20 },
                "point_after" => { "x" => 13, "y" => 20 },
                "over_bit" => true,
                "inverse_bit" => false,
              },
            ],
          },
        ],
      },
    }

    frame = described_class.new(game_data).frame_for_picture(6)

    expect(frame.fetch("toggle_rows")[155][11, 3]).to eq("111")
  end

end
