# frozen_string_literal: true

require "spec_helper"
require "paws/graphics/drawstring_preview_renderer"

RSpec.describe PAWS::Graphics::DrawstringPreviewRenderer do
  it "renders plot and line commands to a bitmap" do
    result = described_class.new.render(
      [
        {
          "family" => 0,
          "point_after" => { "x" => 10, "y" => 10 },
          "pixel_effect" => "set",
        },
        {
          "family" => 1,
          "point_before" => { "x" => 10, "y" => 10 },
          "point_after" => { "x" => 13, "y" => 10 },
          "pixel_effect" => "set",
        },
        {
          "family" => 5,
        },
      ]
    )

    expect(result.commands_seen).to eq(3)
    expect(result.commands_rendered).to eq(2)
    expect(result.commands_skipped).to eq(1)
    expect(result.pixels_set).to eq(4)
    expect(result.pixels[165][10]).to be true
    expect(result.pixels[165][13]).to be true
  end

  it "exports PBM data for visual inspection" do
    renderer = described_class.new
    result = renderer.render([{ "family" => 0, "point_after" => { "x" => 0, "y" => 0 } }])

    lines = renderer.to_pbm(result).lines
    expect(lines[0]).to eq("P1\n")
    expect(lines[1]).to eq("256 192\n")
    expect(lines[177]).to start_with("1")
  end

  it "does not draw pixel-neutral moves but updates absolute move attributes" do
    result = described_class.new.render(
      [
        {
          "family" => 0,
          "point_after" => { "x" => 10, "y" => 10 },
          "pixel_effect" => "move",
        },
        {
          "family" => 1,
          "point_before" => { "x" => 10, "y" => 10 },
          "point_after" => { "x" => 20, "y" => 20 },
          "pixel_effect" => "move",
        },
      ],
      initial_attribute: { "ink" => 6, "paper" => 3 },
      screen_attribute: { "ink" => 7, "paper" => 0 },
    )

    expect(result.commands_seen).to eq(2)
    expect(result.commands_rendered).to eq(1)
    expect(result.commands_skipped).to eq(1)
    expect(result.pixels_set).to eq(0)
    expect(result.attributes[20][1]).to include("ink" => 6, "paper" => 3)
    expect(result.attributes[19][2]).to include("ink" => 7, "paper" => 0)
  end

  it "draws line pixels after the starting point" do
    result = described_class.new.render(
      [
        {
          "family" => 1,
          "point_before" => { "x" => 10, "y" => 10 },
          "point_after" => { "x" => 13, "y" => 10 },
        },
      ],
    )

    expect(result.pixels_set).to eq(3)
    expect(result.pixels[165][10]).to be false
    expect(result.pixels[165][11]).to be true
    expect(result.pixels[165][12]).to be true
    expect(result.pixels[165][13]).to be true
  end

  it "applies INVERSE and OVER pixel effects for plot and line commands" do
    result = described_class.new.render(
      [
        {
          "family" => 0,
          "point_after" => { "x" => 10, "y" => 10 },
        },
        {
          "family" => 1,
          "point_before" => { "x" => 10, "y" => 10 },
          "point_after" => { "x" => 14, "y" => 10 },
        },
        {
          "family" => 1,
          "point_before" => { "x" => 11, "y" => 10 },
          "point_after" => { "x" => 13, "y" => 10 },
          "inverse_bit" => true,
        },
        {
          "family" => 0,
          "point_after" => { "x" => 12, "y" => 10 },
          "over_bit" => true,
        },
      ]
    )

    expect(result.commands_rendered).to eq(4)
    expect(result.pixels[165][10]).to be true
    expect(result.pixels[165][11]).to be true
    expect(result.pixels[165][12]).to be true
    expect(result.pixels[165][13]).to be false
    expect(result.pixels[165][14]).to be true
  end

  it "can render family 2 seed commands for reverse-engineering previews" do
    result = described_class.new(render_family2_seeds: true).render(
      [
        {
          "family" => 2,
          "tip" => { "x" => 10, "y" => 10 },
        },
      ]
    )

    expect(result.commands_seen).to eq(1)
    expect(result.commands_rendered).to eq(1)
    expect(result.pixels_set).to eq(5)
    expect(result.pixels[165][10]).to be true
    expect(result.pixels[165][9]).to be true
    expect(result.pixels[165][11]).to be true
    expect(result.pixels[164][10]).to be true
    expect(result.pixels[166][10]).to be true
  end

  it "keeps the graphics cursor unchanged after family 2 fill endpoints" do
    result = described_class.new(family2_mode: :none).render(
      [
        {
          "family" => 2,
          "name" => "flood_fill",
          "dx" => 10,
          "dy" => 10,
        },
        {
          "family" => 1,
          "dx" => 3,
          "dy" => 0,
        },
      ],
    )

    expect(result.commands_rendered).to eq(1)
    expect(result.commands_skipped).to eq(1)
    expect(result.pixels[165][10]).to be false
    expect(result.pixels[175][3]).to be true
  end

  it "can render family 2 flood-fill commands inside existing outlines" do
    outline = [
      { "family" => 0, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 10 }, "point_after" => { "x" => 14, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 10 }, "point_after" => { "x" => 14, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 14 }, "point_after" => { "x" => 10, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 14 }, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 2, "tip" => { "x" => 12, "y" => 12 } },
    ]

    result = described_class.new(family2_mode: :solid_fill).render(outline)

    expect(result.commands_rendered).to eq(6)
    expect(result.pixels[163][12]).to be true
  end

  it "allows PAW fills larger than a small safety threshold" do
    commands = [
      { "family" => 0, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 10 }, "point_after" => { "x" => 90, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 90, "y" => 10 }, "point_after" => { "x" => 90, "y" => 90 } },
      { "family" => 1, "point_before" => { "x" => 90, "y" => 90 }, "point_after" => { "x" => 10, "y" => 90 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 90 }, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 2, "tip" => { "x" => 50, "y" => 50 } },
    ]

    result = described_class.new(family2_mode: :solid_fill).render(commands)

    expect(result.pixels_set).to be > 4096
  end

  it "still rejects unbounded fills that would consume most of the screen" do
    result = described_class.new(family2_mode: :solid_fill, allow_edge_fills: true).render(
      [
        { "family" => 2, "tip" => { "x" => 50, "y" => 50 } },
      ],
    )

    expect(result.commands_rendered).to eq(0)
    expect(result.commands_skipped).to eq(1)
  end

  it "rejects escaped edge fills once they exceed the PAW-sized work area" do
    result = described_class.new(family2_mode: :solid_fill, allow_edge_fills: true).render(
      [
        { "family" => 0, "point_after" => { "x" => 80, "y" => 10 } },
        { "family" => 1, "point_before" => { "x" => 80, "y" => 10 }, "point_after" => { "x" => 80, "y" => 90 } },
        { "family" => 2, "tip" => { "x" => 20, "y" => 50 } },
      ],
    )

    expect(result.commands_rendered).to eq(2)
    expect(result.commands_skipped).to eq(1)
  end

  it "can allow family 2 fills that touch the screen edge when explicitly enabled" do
    commands = [
      { "family" => 0, "point_after" => { "x" => 3, "y" => 0 } },
      { "family" => 1, "point_before" => { "x" => 3, "y" => 0 }, "point_after" => { "x" => 3, "y" => 4 } },
      { "family" => 1, "point_before" => { "x" => 3, "y" => 4 }, "point_after" => { "x" => 0, "y" => 4 } },
      { "family" => 2, "tip" => { "x" => 1, "y" => 1 }, "pattern_byte" => 0xFF },
    ]

    blocked = described_class.new(family2_mode: :shade_byte_fill).render(commands)
    allowed = described_class.new(family2_mode: :shade_byte_fill, allow_edge_fills: true).render(commands)

    expect(blocked.commands_rendered).to eq(3)
    expect(allowed.commands_rendered).to eq(4)
    expect(allowed.pixels_set).to be > blocked.pixels_set
  end

  it "can render family 2 shade-byte commands with built-in fallback patterns" do
    outline = [
      { "family" => 0, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 10 }, "point_after" => { "x" => 14, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 10 }, "point_after" => { "x" => 14, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 14 }, "point_after" => { "x" => 10, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 14 }, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 2, "tip" => { "x" => 12, "y" => 12 }, "pattern_byte" => 0xFF },
    ]

    result = described_class.new(family2_mode: :shade_byte_fill).render(outline)

    expect(result.commands_rendered).to eq(6)
    expect(result.pixels[163][12]).to be true
  end

  it "renders family 2 shade-byte commands with extracted PAW shade patterns" do
    outline = [
      { "family" => 0, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 10 }, "point_after" => { "x" => 14, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 10 }, "point_after" => { "x" => 14, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 14 }, "point_after" => { "x" => 10, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 14 }, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 2, "tip" => { "x" => 12, "y" => 12 }, "pattern_byte" => 0x00 },
    ]
    shade_patterns = {
      "patterns" => {
        "0" => [0b10000000, 0, 0, 0, 0, 0, 0, 0],
      },
    }

    result = described_class.new(family2_mode: :shade_byte_fill, shade_patterns: shade_patterns).render(outline)

    expect(result.commands_rendered).to eq(6)
    expect(result.pixels[163][10]).to be true
    expect(result.pixels[163][11]).to be false
  end

  it "renders semantic flood fills as solid when shade-byte mode is active" do
    outline = [
      { "family" => 0, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 10 }, "point_after" => { "x" => 14, "y" => 10 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 10 }, "point_after" => { "x" => 14, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 14, "y" => 14 }, "point_after" => { "x" => 10, "y" => 14 } },
      { "family" => 1, "point_before" => { "x" => 10, "y" => 14 }, "point_after" => { "x" => 10, "y" => 10 } },
      { "family" => 2, "name" => "flood_fill", "tip" => { "x" => 12, "y" => 12 } },
    ]

    result = described_class.new(family2_mode: :shade_byte_fill).render(outline)

    expect(result.commands_rendered).to eq(6)
    expect(result.pixels[163][12]).to be true
  end

  it "renders standard Spectrum character glyphs used by drawstrings" do
    result = described_class.new.render(
      [
        { "family" => 4, "character" => 0x4F, "character_x" => 29, "character_y" => 4 },
      ],
    )

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels[33][234]).to be true
    expect(result.pixels[34][233]).to be true
    expect(result.pixels[34][238]).to be true
    expect(result.pixels[38][237]).to be true
  end

  it "clears the full drawstring character cell before plotting glyph bits" do
    result = described_class.new.render(
      [
        { "family" => 0, "point_after" => { "x" => 239, "y" => 143 } },
        { "family" => 1, "dx" => 0, "dy" => -3, "point_after" => { "x" => 239, "y" => 140 } },
        { "family" => 4, "character" => 0x4F, "character_x" => 29, "character_y" => 4 },
      ],
    )

    expect(result.pixels[32][239]).to be false
    expect(result.pixels[33][239]).to be false
    expect(result.pixels[34][238]).to be true
  end

  it "renders drawstring characters from the active extracted charset" do
    result = described_class.new(
      charsets: {
        "entries" => [
          { "id" => 2, "glyphs" => { "65" => [0b10000000, 0, 0, 0, 0, 0, 0, 0] } },
        ],
      },
      charset_id: 2,
    ).render(
      [
        { "family" => 4, "character" => 65, "character_x" => 1, "character_y" => 2 },
      ],
    )

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels[16][8]).to be true
    expect(result.pixels[16][9]).to be false
  end

  it "renders Spectrum block graphics and UDG drawstring characters" do
    result = described_class.new(
      udgs: {
        "glyphs" => { "144" => [0b00000001, 0, 0, 0, 0, 0, 0, 0] },
      },
    ).render(
      [
        { "family" => 4, "character" => 129, "character_x" => 1, "character_y" => 2 },
        { "family" => 4, "character" => 144, "character_x" => 3, "character_y" => 2 },
      ],
    )

    expect(result.commands_rendered).to eq(2)
    expect(result.pixels[16][8]).to be true
    expect(result.pixels[16][12]).to be false
    expect(result.pixels[16][31]).to be true
  end

  it "tracks Spectrum attributes per 8x8 cell while drawing" do
    result = described_class.new.render(
      [
        { "family" => 5, "control" => "paper", "control_value" => 5 },
        { "family" => 6, "control" => "ink", "control_value" => 2 },
        { "family" => 0, "point_after" => { "x" => 16, "y" => 16 } },
      ],
      initial_attribute: { "ink" => 0, "paper" => 7 },
    )

    attr = result.attributes[19][2]

    expect(attr).to include("ink" => 2, "paper" => 5)
    expect(result.pixels[159][16]).to be true
  end

  it "can keep untouched screen cells and plotted paper on a separate base attribute" do
    result = described_class.new.render(
      [
        { "family" => 0, "point_after" => { "x" => 16, "y" => 16 } },
      ],
      initial_attribute: { "ink" => 5, "paper" => 3 },
      screen_attribute: { "ink" => 7, "paper" => 0 },
    )

    expect(result.attributes[0][0]).to include("ink" => 7, "paper" => 0)
    expect(result.attributes[19][2]).to include("ink" => 5, "paper" => 3)
  end

  it "fills attribute cells enclosed by a PAPER-coloured polygon" do
    result = described_class.new.render(
      [
        { "family" => 5, "control" => "paper", "control_value" => 6 },
        { "family" => 6, "control" => "ink", "control_value" => 5 },
        { "family" => 1, "point_before" => { "x" => 112, "y" => 109 }, "point_after" => { "x" => 144, "y" => 127 } },
        { "family" => 1, "point_before" => { "x" => 144, "y" => 127 }, "point_after" => { "x" => 150, "y" => 127 } },
        { "family" => 1, "point_before" => { "x" => 150, "y" => 127 }, "point_after" => { "x" => 150, "y" => 109 } },
        { "family" => 5, "control" => "paper", "control_value" => 0 },
      ],
      initial_attribute: { "ink" => 7, "paper" => 0 },
      screen_attribute: { "ink" => 7, "paper" => 0 },
    )

    expect(result.attributes[6][16]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[6][17]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[6][18]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[7][15]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[7][16]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[7][17]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[7][18]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[0][0]).to include("ink" => 7, "paper" => 0)
  end

  it "can preserve existing paper attributes for PAW v1 pixel operations" do
    result = described_class.new(preserve_paper_on_pixel_attributes: true).render(
      [
        { "family" => 5, "control" => "paper", "control_value" => 6 },
        { "family" => 6, "control" => "ink", "control_value" => 5 },
        { "family" => 1, "point_before" => { "x" => 112, "y" => 109 }, "point_after" => { "x" => 144, "y" => 127 } },
        { "family" => 1, "point_before" => { "x" => 144, "y" => 127 }, "point_after" => { "x" => 150, "y" => 127 } },
        { "family" => 1, "point_before" => { "x" => 150, "y" => 127 }, "point_after" => { "x" => 150, "y" => 109 } },
        { "family" => 5, "control" => "paper", "control_value" => 0 },
        { "family" => 2, "name" => "flood_fill", "tip" => { "x" => 126, "y" => 125 } },
      ],
      initial_attribute: { "ink" => 7, "paper" => 0 },
      screen_attribute: { "ink" => 7, "paper" => 0 },
    )

    expect(result.attributes[6][16]).to include("ink" => 5, "paper" => 6)
    expect(result.attributes[7][15]).to include("ink" => 5, "paper" => 6)
  end

  it "applies family 2 attribute blocks without changing bitmap pixels" do
    result = described_class.new.render(
      [
        { "family" => 5, "control" => "paper", "control_value" => 1 },
        {
          "family" => 2,
          "name" => "attribute_block",
          "attribute_block" => {
            "attribute_x" => 4,
            "attribute_y" => 3,
            "width_attributes" => 2,
            "height_attributes" => 1,
          },
        },
      ],
    )

    expect(result.attributes[3][4]).to include("paper" => 1)
    expect(result.attributes[3][5]).to include("paper" => 1)
    expect(result.pixels_set).to eq(0)
  end

  it "applies OVER family 2 attribute blocks as full attribute updates" do
    result = described_class.new.render(
      [
        { "family" => 5, "control" => "paper", "control_value" => 6 },
        { "family" => 5, "control" => "paper", "control_value" => 0 },
        {
          "family" => 2,
          "name" => "attribute_block",
          "over_bit" => true,
          "attribute_block" => {
            "attribute_x" => 4,
            "attribute_y" => 3,
            "width_attributes" => 1,
            "height_attributes" => 1,
          },
        },
      ],
      initial_attribute: { "ink" => 2, "paper" => 6 },
      screen_attribute: { "ink" => 7, "paper" => 6 },
    )

    expect(result.attributes[3][4]).to include("ink" => 2, "paper" => 0)
    expect(result.pixels_set).to eq(0)
  end

  it "preserves existing attribute components when INK or PAPER are transparent" do
    result = described_class.new.render(
      [
        { "family" => 6, "control" => "ink", "control_value" => 8 },
        { "family" => 5, "control" => "paper", "control_value" => 8 },
        { "family" => 0, "point_after" => { "x" => 16, "y" => 16 } },
        {
          "family" => 2,
          "name" => "attribute_block",
          "attribute_block" => {
            "attribute_x" => 2,
            "attribute_y" => 19,
            "width_attributes" => 1,
            "height_attributes" => 1,
          },
        },
      ],
      initial_attribute: { "ink" => 1, "paper" => 2 },
      screen_attribute: { "ink" => 6, "paper" => 4 },
    )

    expect(result.attributes[19][2]).to include("ink" => 6, "paper" => 4)
  end

  it "preserves existing attribute components when BRIGHT or FLASH are transparent" do
    result = described_class.new.render(
      [
        { "family" => 6, "control" => "bright", "control_value" => 8 },
        { "family" => 6, "control" => "flash", "control_value" => 8 },
        { "family" => 0, "point_after" => { "x" => 16, "y" => 16 } },
        {
          "family" => 2,
          "name" => "attribute_block",
          "attribute_block" => {
            "attribute_x" => 2,
            "attribute_y" => 19,
            "width_attributes" => 1,
            "height_attributes" => 1,
          },
        },
      ],
      initial_attribute: { "ink" => 1, "paper" => 2, "bright" => false, "flash" => false },
      screen_attribute: { "ink" => 6, "paper" => 4, "bright" => true, "flash" => true },
    )

    expect(result.attributes[19][2]).to include("bright" => true, "flash" => true)
  end

  it "skips malformed family 2 block commands without decoded attribute metadata" do
    result = described_class.new(family2_mode: :shade_byte_fill).render(
      [
        {
          "family" => 2,
          "opcode" => 0x12,
          "current_parse_length" => 5,
          "tip" => { "x" => 12, "y" => 12 },
          "pattern_byte" => 0xFF,
        },
      ]
    )

    expect(result.commands_seen).to eq(1)
    expect(result.commands_rendered).to eq(0)
    expect(result.commands_skipped).to eq(1)
    expect(result.pixels_set).to eq(0)
  end

  it "can render known family 4 character commands" do
    result = described_class.new.render(
      [
        {
          "family" => 4,
          "character" => 0x7F,
          "character_x" => 24,
          "character_y" => 15,
        },
      ]
    )

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels_set).to eq(36)
    expect(result.pixels[120][193]).to be true
    expect(result.pixels[121][192]).to be true
    expect(result.pixels[127][198]).to be true
  end

  it "can inline valid GOSUB picture commands for preview rendering" do
    result = described_class.new(
      pictures_by_id: {
        2 => [
          {
            "family" => 0,
            "point_after" => { "x" => 20, "y" => 20 },
          },
        ],
      }
    ).render([{ "family" => 3, "picture" => 2 }])

    expect(result.commands_seen).to eq(2)
    expect(result.commands_rendered).to eq(1)
    expect(result.commands_skipped).to eq(0)
    expect(result.pixels[155][20]).to be true
  end

  it "executes GOSUB picture commands with the caller graphics cursor" do
    result = described_class.new(
      pictures_by_id: {
        2 => [
          {
            "family" => 1,
            "dx" => 3,
            "dy" => 0,
          },
        ],
      }
    ).render(
      [
        {
          "family" => 0,
          "x" => 20,
          "y" => 20,
          "pixel_effect" => "move",
        },
        { "family" => 3, "picture" => 2 },
      ]
    )

    expect(result.commands_rendered).to eq(2)
    expect(result.pixels[155][20]).to be false
    expect(result.pixels[155][21]).to be true
    expect(result.pixels[155][23]).to be true
  end

  it "scales relative line commands inside GOSUB pictures in eighths" do
    result = described_class.new(
      pictures_by_id: {
        2 => [
          {
            "family" => 1,
            "dx" => 8,
            "dy" => 0,
          },
        ],
      },
    ).render([{ "family" => 3, "picture" => 2, "scale" => 4 }])

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels_set).to eq(4)
    expect(result.pixels[175][1]).to be true
    expect(result.pixels[175][4]).to be true
    expect(result.pixels[175][5]).to be false
  end

  it "scales family 2 relative fill endpoints inside GOSUB pictures" do
    result = described_class.new(
      render_family2_seeds: true,
      pictures_by_id: {
        2 => [
          {
            "family" => 2,
            "dx" => 8,
            "dy" => 0,
          },
        ],
      },
    ).render([{ "family" => 3, "picture" => 2, "scale" => 4 }])

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels[175][4]).to be true
    expect(result.pixels[175][8]).to be false
  end

  it "does not apply an outer GOSUB scale to nested GOSUB commands" do
    result = described_class.new(
      pictures_by_id: {
        2 => [
          { "family" => 3, "picture" => 3 },
        ],
        3 => [
          {
            "family" => 1,
            "dx" => 8,
            "dy" => 0,
          },
        ],
      },
    ).render([{ "family" => 3, "picture" => 2, "scale" => 4 }])

    expect(result.commands_rendered).to eq(1)
    expect(result.pixels_set).to eq(8)
    expect(result.pixels[175][4]).to be true
    expect(result.pixels[175][8]).to be true
  end

  it "skips invalid or recursive GOSUB picture commands" do
    result = described_class.new(
      pictures_by_id: {
        2 => [{ "family" => 3, "picture" => 2 }],
      }
    ).render([{ "family" => 3, "picture" => 47 }])

    expect(result.commands_seen).to eq(1)
    expect(result.commands_rendered).to eq(0)
    expect(result.commands_skipped).to eq(1)

    recursive = described_class.new(
      pictures_by_id: {
        2 => [{ "family" => 3, "picture" => 2 }],
      }
    ).render([{ "family" => 3, "picture" => 2 }])

    expect(recursive.commands_seen).to eq(2)
    expect(recursive.commands_rendered).to eq(0)
    expect(recursive.commands_skipped).to eq(1)
  end
end
