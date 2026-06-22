# frozen_string_literal: true

require "spec_helper"
require "paws/web/screen_model"

RSpec.describe PAWS::Web::ScreenModel do
  subject(:model) { described_class.new }

  let(:frame) do
    {
      "type" => "screen.frame",
      "picture_id" => 1,
      "visible_height" => 136,
      "full_screen" => false,
    }
  end

  it "promotes a location frame to a full Spectrum screen with a text window" do
    prepared, cursor = model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    expect(prepared).to include(
      "visible_height" => 192,
      "full_screen" => true,
      "text_window_start_row" => 17,
      "text_window_ink" => "green",
      "text_window_paper" => "black",
    )
    expect(cursor).to eq(row: 17, col: 0)
  end

  it "keeps exact bottom-aligned inferred text outside the Spectrum screen" do
    expect(model.text_start_row(frame, graphics_line: nil)).to be_nil
  end

  it "does not create a text window when the inferred row is outside the visible frame" do
    short_frame = frame.merge("visible_height" => 96)

    prepared, cursor = model.frame_with_text_window(short_frame, graphics_line: 24, ink: "green", paper: "black")

    expect(prepared).to eq(short_frame)
    expect(cursor).to be_nil
  end

  it "advances the cursor using visible characters and explicit newlines" do
    model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    event = model.append_text_event(
      { "type" => "text.append", "text" => "Hola\nmundo", "newline" => true },
      colors: { ink: "white", paper: "black", bright: false, flash: true },
    )

    expect(event).to include(
      "type" => "screen.text",
      "row" => 17,
      "col" => 0,
      "text" => "Hola\nmundo",
      "newline" => true,
      "flash" => true,
    )
    expect(model.cursor).to eq(row: 19, col: 0)
  end

  it "wraps at the Spectrum text width" do
    model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    model.append_text_event(
      { "type" => "text.append", "text" => "x" * 33, "newline" => false },
      colors: {},
    )

    expect(model.cursor).to eq(row: 18, col: 1)
  end

  it "wraps prose on word boundaries before emitting screen text" do
    model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    event = model.append_text_event(
      { "type" => "text.append", "text" => "Est{glyph:64:á}s dentro de la fabrica de hielo.", "newline" => false },
      colors: {},
    )

    expect(event).to include(
      "row" => 17,
      "col" => 0,
      "text" => "Est{glyph:64:á}s dentro de la fabrica de\nhielo.",
    )
    expect(model.cursor).to eq(row: 18, col: 6)
  end

  it "advances over PAWS line-break control runs" do
    model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    model.append_text_event(
      { "type" => "text.append", "text" => "Uno{6}{6}Dos", "newline" => false },
      colors: {},
    )

    expect(model.cursor).to eq(row: 18, col: 3)
  end

  it "paginates Spectrum window text before writing visible text on the prompt row" do
    model.frame_with_text_window(frame, graphics_line: 17, ink: "green", paper: "black")

    events = model.append_paginated_text_events(
      { "type" => "text.append", "text" => (["linea"] * 8).join("\n"), "newline" => false },
      colors: { ink: "white", paper: "black", bright: false, flash: false },
      bottom_row: 23,
    )

    expect(events.map { |event| event["type"] }).to eq(["screen.text", "input.request", "screen.text", "screen.scroll", "screen.text"])
    expect(events[0]).to include("row" => 17, "text" => "linea\nlinea\nlinea\nlinea\nlinea\nlinea\n")
    expect(events[1]).to include("mode" => "key")
    expect(events[2]).to include("row" => 23, "col" => 0, "text" => " " * 32)
    expect(events[3]).to include("lines" => 4)
    expect(events[4]).to include("row" => 19, "text" => "linea\nlinea")
    expect(model.cursor).to eq(row: 20, col: 5)
  end
end
