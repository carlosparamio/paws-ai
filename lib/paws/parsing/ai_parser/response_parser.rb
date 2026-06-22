# frozen_string_literal: true

require "json"

module PAWS
  # Normalizes model responses into the compact JSON shape used by ParsedCommand.
  # This class is intentionally tolerant of provider differences: it accepts
  # either message.content or message.reasoning and strips Markdown fences before
  # JSON parsing.
  class AIResponseParser
    def initialize(logger: nil, warn: nil)
      @logger = logger
      @warn = warn || ->(message) { Kernel.warn(message) }
    end

    def parse(body)
      body = JSON.parse(body) if body.is_a?(String)

      message = body.dig("choices", 0, "message")
      content = message&.dig("content") || message&.dig("reasoning")

      if content.nil?
        warn.call("AI Parser API Error: No content/reasoning in response. Body: #{body}")
        return nil
      end

      logger&.call("🤖 AI raw response: #{content}", 3)
      parsed = JSON.parse(json_text(content))
      return parsed if parsed.is_a?(Hash)

      warn.call("AI Parser JSON Error: expected an object, got #{parsed.class}. Content: #{content}")
      nil
    rescue JSON::ParserError => e
      warn.call("AI Parser JSON Error: #{e.message}. Content: #{content}")
      nil
    end

    private

    attr_reader :logger, :warn

    def json_text(content)
      content.gsub(/```json\s*|\s*```/m, "").strip
    end
  end
end
