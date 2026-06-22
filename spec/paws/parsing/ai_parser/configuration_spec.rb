# frozen_string_literal: true

require "spec_helper"
require "paws/parsing/ai_parser/configuration"

RSpec.describe PAWS::AIParserConfiguration do
  it "loads OpenAI-compatible settings from the environment boundary" do
    config = described_class.from_env(
      "AI_PARSER_API_KEY" => "key",
      "AI_PARSER_ENDPOINT" => "https://example.test/api",
      "AI_PARSER_MODEL" => "provider/model",
    )

    expect(config.api_key).to eq("key")
    expect(config.endpoint).to eq("https://example.test/api")
    expect(config.model).to eq("provider/model")
  end

  it "requires endpoint and model configuration" do
    expect do
      described_class.new(api_key: "key", endpoint: "", model: " ")
    end.to raise_error(ArgumentError, /AI_PARSER_ENDPOINT/)
  end

  it "requires model configuration" do
    expect do
      described_class.new(api_key: "key", endpoint: "https://example.test/api", model: " ")
    end.to raise_error(ArgumentError, /AI_PARSER_MODEL/)
  end

  it "requires API key configuration" do
    expect do
      described_class.new(api_key: nil, endpoint: "https://example.test/api", model: "provider/model")
    end.to raise_error(ArgumentError, /AI_PARSER_API_KEY/)
  end
end
