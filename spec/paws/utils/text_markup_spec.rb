# frozen_string_literal: true

require "spec_helper"
require "paws/utils/text_markup"

RSpec.describe PAWS::TextMarkup do
  it "renders glyph placeholders using their fallback character" do
    expect(described_class.render_glyph_tags("peque{glyph:124:ñ}o")).to eq("pequeño")
  end

  it "strips PAWS tags after rendering glyph placeholders" do
    expect(described_class.strip_tags("{ink:red}peque{glyph:124:ñ}o")).to eq("pequeño")
  end

  it "renders PAWS line-break control runs before stripping other tags" do
    expect(described_class.strip_tags("Has jugado...{6}{6}{glyph:93:¿}La Aventura?")).to eq("Has jugado...\n¿La Aventura?")
  end

  it "wraps screen text at word boundaries while preserving markup" do
    wrapped = described_class.wrap_screen_text(
      "Est{glyph:64:á}s dentro de la fabrica de hielo.",
      initial_col: 0,
      width: 32,
    )

    expect(wrapped).to eq("Est{glyph:64:á}s dentro de la fabrica de\nhielo.")
  end

  it "treats compact sentence starts as Spectrum line breaks" do
    wrapped = described_class.wrap_screen_text(
      "mercadillo.La gente mira.SALIDAS: Sur.",
      initial_col: 0,
      width: 32,
    )

    expect(wrapped).to eq("mercadillo.\nLa gente mira.\nSALIDAS: Sur.")
  end

  it "keeps normal spaced sentences and ellipses intact" do
    wrapped = described_class.wrap_screen_text(
      "hielo. A pesar...Otra vez",
      initial_col: 0,
      width: 32,
    )

    expect(wrapped).to eq("hielo. A pesar...Otra vez")
  end

  it "treats compact glyph sentence starts as Spectrum line breaks" do
    wrapped = described_class.wrap_screen_text(
      "Hecho.{glyph:93:¿}Otra cosa?",
      initial_col: 0,
      width: 32,
    )

    expect(wrapped).to eq("Hecho.\n{glyph:93:¿}Otra cosa?")
  end

  it "keeps colour tags with the wrapped word" do
    wrapped = described_class.wrap_screen_text(
      "Uno {ink:green}dos",
      initial_col: 29,
      width: 32,
    )

    expect(wrapped).to eq("Uno{ink:green}\ndos")
  end

  it "identifies inline formatting-only text" do
    expect(described_class.formatting_only?("{paper:blue}     ")).to be true
    expect(described_class.formatting_only?("  texto")).to be false
  end
end
