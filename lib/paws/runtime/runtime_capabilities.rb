# frozen_string_literal: true

module PAWS
  # Structured explanation for a runtime capability decision.
  # It preserves a readable string form for logs while exposing feature/type for
  # tests, debuggers, and future interfaces that want more than plain text.
  CapabilityReason = Struct.new(:feature, :message, :type, keyword_init: true) do
    def to_s
      message
    end

    def unsupported?
      type == :unsupported
    end

    def optional_noop?
      type == :optional_noop
    end
  end

  # Describes platform features available to the PAWS runtime.
  # Condact handlers ask this object why a capability is unsupported or why an
  # effect is intentionally a no-op instead of hard-coding platform assumptions.
  class RuntimeCapabilities
    CLI_UNSUPPORTED = {
      screen_border_color: "screen border color is unavailable in the Ruby CLI runtime",
      graphics_line_positioning: "graphics line positioning is unavailable in the Ruby CLI runtime",
      picture_loading: "picture loading is unavailable in the Ruby CLI runtime",
      graphics_mode: "graphics mode is unavailable in the Ruby CLI runtime",
      cursor_positioning: "cursor positioning is unavailable in the Ruby CLI runtime",
      external_routine_calls: "external routine calls are unavailable in the Ruby runtime",
      direct_memory_access: "direct memory access is unavailable in the Ruby runtime",
    }.freeze

    CLI_OPTIONAL_NOOPS = {
      sound: "sound is optional in the CLI runtime",
      copy_protection: "copy protection has no runtime effect here",
    }.freeze

    def self.cli
      new(unsupported: CLI_UNSUPPORTED, optional_noops: CLI_OPTIONAL_NOOPS)
    end

    def self.web
      new(
        unsupported: CLI_UNSUPPORTED,
        optional_noops: CLI_OPTIONAL_NOOPS,
        screen_graphics: true,
      )
    end

    def initialize(unsupported:, optional_noops:, screen_graphics: false)
      @unsupported = unsupported
      @optional_noops = optional_noops
      @screen_graphics = screen_graphics
    end

    def screen_graphics?
      @screen_graphics
    end

    def unsupported_reason(feature)
      CapabilityReason.new(
        feature: feature,
        message: @unsupported.fetch(feature),
        type: :unsupported,
      )
    end

    def optional_noop_reason(feature)
      CapabilityReason.new(
        feature: feature,
        message: @optional_noops.fetch(feature),
        type: :optional_noop,
      )
    end
  end
end
