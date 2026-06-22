# frozen_string_literal: true

module PAWS
  # Parser result object shared by classic and AI-assisted parsers.
  # It keeps parser output explicit before Engine copies values into PAWS system flags.
  class ParsedCommand
    attr_reader :verb, :noun1, :noun2, :adject1, :adject2, :adverb, :prep, :quoted_command

    def self.from_ai_result(result)
      new(
        verb: normalize_id(result["verb"]),
        noun1: normalize_id(result["noun1"] || result["noun"]),
        noun2: normalize_id(result["noun2"]),
        adject1: normalize_id(result["adject1"] || result["adjective"]),
        adject2: normalize_id(result["adject2"]),
        adverb: normalize_id(result["adverb"]),
        prep: normalize_id(result["prep"]),
        quoted_command: normalize_quoted_command(result["quoted_command"]),
      )
    end

    def self.normalize_id(value)
      return nil if value.nil?

      normalized = Integer(value, exception: false)
      return nil unless normalized&.positive?

      normalized
    end

    def self.normalize_quoted_command(value)
      return nil unless value.is_a?(String)

      normalized = value.strip
      normalized.empty? ? nil : normalized
    end
    private_class_method :normalize_id, :normalize_quoted_command

    def initialize(verb: nil, noun1: nil, noun2: nil, adject1: nil, adject2: nil, adverb: nil, prep: nil, quoted_command: nil)
      @verb = verb
      @noun1 = noun1
      @noun2 = noun2
      @adject1 = adject1
      @adject2 = adject2
      @adverb = adverb
      @prep = prep
      @quoted_command = quoted_command
    end

    def empty?
      [verb, noun1, noun2, adject1, adject2, adverb, prep].all?(&:nil?) &&
        quoted_command.to_s.strip.empty?
    end
  end
end
