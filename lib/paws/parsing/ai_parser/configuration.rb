# frozen_string_literal: true

module PAWS
  # Configuration object for the AI-assisted parser.
  # It centralizes model and endpoint selection so AIParser can remain a small
  # application service and tests can exercise multiple OpenAI-compatible models
  # without reaching into environment variables or transport details.
  class AIParserConfiguration
    DEFAULT_REFERER = "https://github.com/carlosparamio/paws-ai"
    DEFAULT_TITLE = "PAWS-AI Engine"

    attr_reader :api_key, :endpoint, :model, :referer, :title

    def self.from_env(env = ENV)
      new(
        api_key: env["AI_PARSER_API_KEY"],
        endpoint: env["AI_PARSER_ENDPOINT"],
        model: env["AI_PARSER_MODEL"],
      )
    end

    def initialize(
      api_key: nil,
      endpoint: nil,
      model: nil,
      referer: DEFAULT_REFERER,
      title: DEFAULT_TITLE
    )
      @api_key = required_value(api_key, "AI_PARSER_API_KEY")
      @endpoint = required_value(endpoint, "AI_PARSER_ENDPOINT")
      @model = required_value(model, "AI_PARSER_MODEL")
      @referer = referer
      @title = title
    end

    private

    def required_value(value, name)
      text = value.to_s.strip
      raise ArgumentError, "#{name} is required when AI parser is enabled" if text.empty?

      text
    end
  end
end
