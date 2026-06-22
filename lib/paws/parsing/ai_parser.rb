# frozen_string_literal: true

require_relative "parsed_command"
require_relative "ai_parser/configuration"
require_relative "ai_parser/open_ai_chat_client"
require_relative "ai_parser/prompt_builder"
require_relative "ai_parser/response_parser"

module PAWS
  # Natural language parser assisted by AI.
  # This class is the stable facade used by Engine: callers ask for a
  # ParsedCommand and do not need to know how prompts are built, which
  # OpenAI-compatible endpoint is used, or how provider responses are cleaned.
  #
  # Internally it composes three collaborators:
  # AIPromptBuilder prepares messages, OpenAIChatClient performs HTTP transport,
  # and AIResponseParser normalizes model output. Keeping the facade named
  # AIParser preserves the domain concept even if OpenRouter is later replaced.
  class AIParser
    DEFAULT_REFERER = AIParserConfiguration::DEFAULT_REFERER
    DEFAULT_TITLE = AIParserConfiguration::DEFAULT_TITLE
    UNSET = Object.new.freeze

    def self.parse(input, context, engine: nil)
      logger = engine ? ->(message, level) { engine.log(message, level) } : nil
      new(logger: logger).parse(input, context: context)
    end

    def initialize(
      api_key: UNSET,
      endpoint: UNSET,
      model: UNSET,
      http_client: nil,
      template_loader: nil,
      logger: nil,
      referer: UNSET,
      title: UNSET,
      configuration: nil,
      prompt_builder: nil,
      client: nil,
      response_parser: nil
    )
      source = configuration
      @configuration = AIParserConfiguration.new(
        api_key: configured(:api_key, api_key, source),
        endpoint: configured(:endpoint, endpoint, source),
        model: configured(:model, model, source),
        referer: configured_optional(:referer, referer, source, DEFAULT_REFERER),
        title: configured_optional(:title, title, source, DEFAULT_TITLE),
      )
      @model = @configuration.model
      @logger = logger
      warning = ->(message) { warn(message) }
      @prompt_builder = prompt_builder || AIPromptBuilder.new(template_loader: template_loader, warn: warning)
      @client = client || OpenAIChatClient.new(
        api_key: @configuration.api_key,
        endpoint: @configuration.endpoint,
        http_client: http_client,
        referer: @configuration.referer,
        title: @configuration.title,
        warn: warning,
      )
      @response_parser = response_parser || AIResponseParser.new(logger: logger, warn: warning)
    end

    def parse(input, context:)
      result = parse_raw(input, context)
      result ? ParsedCommand.from_ai_result(result) : nil
    end

    def parse_raw(input, context)
      payload = @prompt_builder.request_payload(input, context, model: @model)
      return nil unless payload

      @logger&.call("🤖 AI request payload: #{payload}", 3)
      body = @client.post_chat(payload)
      body ? @response_parser.parse(body) : nil
    end

    private

    def configured(attribute, override, source)
      return override unless override.equal?(UNSET)
      return source.public_send(attribute) if source

      ENV["AI_PARSER_#{attribute.to_s.upcase}"]
    end

    def configured_optional(attribute, override, source, fallback)
      return override unless override.equal?(UNSET)
      return source.public_send(attribute) if source

      fallback
    end
  end
end
