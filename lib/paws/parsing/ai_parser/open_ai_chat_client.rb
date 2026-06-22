# frozen_string_literal: true

require "faraday"
require_relative "configuration"

module PAWS
  # HTTP adapter for OpenAI-compatible chat completions APIs.
  # This is the outbound port implementation used by AIParser today. OpenRouter
  # is only the default endpoint; the adapter itself speaks the generic
  # chat/completions shape so alternative model gateways can be tested by
  # swapping configuration or injecting another client object.
  class OpenAIChatClient
    DEFAULT_REFERER = AIParserConfiguration::DEFAULT_REFERER
    DEFAULT_TITLE = AIParserConfiguration::DEFAULT_TITLE

    def initialize(
      api_key:,
      endpoint:,
      http_client: nil,
      referer: DEFAULT_REFERER,
      title: DEFAULT_TITLE,
      warn: nil
    )
      @api_key = api_key
      @endpoint = endpoint
      @http_client = http_client
      @referer = referer
      @title = title
      @warn = warn || ->(message) { Kernel.warn(message) }
    end

    def post_chat(payload)
      return nil if api_key.nil? || api_key.empty?

      response = http_client.post("chat/completions") do |req|
        req.headers["Authorization"] = "Bearer #{api_key}"
        req.headers["HTTP-Referer"] = referer
        req.headers["X-Title"] = title
        req.body = payload
      end

      return response_body(response) if response.success?

      warn.call("AI Parser API Error: #{response.status} - #{response.body}")
      nil
    rescue => e
      warn.call("AI Parser Exception: #{e.message}")
      nil
    end

    private

    attr_reader :api_key, :endpoint, :referer, :title, :warn

    def http_client
      @http_client ||= Faraday.new(url: endpoint) do |faraday|
        faraday.request :json
        faraday.response :json
        faraday.adapter Faraday.default_adapter
      end
    end

    def response_body(response)
      response.body
    end
  end
end
