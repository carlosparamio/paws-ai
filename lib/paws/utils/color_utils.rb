module PAWS
  # Utility for converting PAWS color names and formatting tags into numeric runtime values.
  # Runtime classes use it as a lookup helper rather than owning color conversion tables themselves.
  class ColorUtils
    COLORS = {
      "black" => 0,
      "blue" => 1,
      "red" => 2,
      "magenta" => 3,
      "green" => 4,
      "cyan" => 5,
      "yellow" => 6,
      "white" => 7,
    }.freeze

    COLOR_NAMES = COLORS.invert.freeze

    # Spectrum to ANSI (standard 8 colors)
    ANSI_COLORS = [
      :black,   # 0
      :blue,    # 1
      :red,     # 2
      :magenta, # 3
      :green,   # 4
      :cyan,    # 5
      :yellow,  # 6
      :white,    # 7
    ].freeze

    def self.to_ansi(color_name)
      # Normalize color name to Spectrum index
      color_id = COLORS[color_name.to_s.downcase] || 7
      ANSI_COLORS[color_id]
    end

    def self.spectrum_color_name(code, contrast_against: 0)
      numeric = code.to_i
      return COLOR_NAMES.fetch(numeric) if COLOR_NAMES.key?(numeric)

      # ZX Spectrum colour 9 is CONTRAST. Against dark papers it behaves as
      # white; against light papers it behaves as black. Colour 8 is transparent
      # in BASIC, so callers should normally preserve the previous colour.
      return contrast_against.to_i < 4 ? "white" : "black" if numeric == 9

      nil
    end
  end
end
