# frozen_string_literal: true

require "spec_helper"
require "faraday"
require "paws/parsing/ai_parser/open_ai_chat_client"

RSpec.describe PAWS::OpenAIChatClient do
  let(:warnings) { [] }
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:http_client) { Faraday.new { |builder| builder.adapter(:test, stubs) } }

  subject(:client) do
    described_class.new(
      api_key: "fake-key",
      endpoint: "https://example.test/api",
      http_client: http_client,
      referer: "https://example.test",
      title: "PAWS Test",
      warn: ->(message) { warnings << message },
    )
  end

  it "posts OpenAI-compatible chat payloads with provider metadata headers" do
    captured_headers = nil
    captured_body = nil
    stubs.post("/chat/completions") do |env|
      captured_headers = env.request_headers
      captured_body = env.body
      [200, { "Content-Type" => "application/json" }, { choices: [] }.to_json]
    end

    result = client.post_chat(model: "provider/model", messages: [])

    expect(JSON.parse(result)).to eq({ "choices" => [] })
    expect(captured_headers["Authorization"]).to eq("Bearer fake-key")
    expect(captured_headers["HTTP-Referer"]).to eq("https://example.test")
    expect(captured_headers["X-Title"]).to eq("PAWS Test")
    expect(captured_body).to eq(model: "provider/model", messages: [])
  end

  it "returns nil and warns on provider errors" do
    stubs.post("/chat/completions") { [400, {}, "bad request"] }

    expect(client.post_chat(model: "provider/model", messages: [])).to be_nil
    expect(warnings.first).to include("AI Parser API Error: 400")
  end

  it "does not post without an API key" do
    keyless_client = described_class.new(api_key: nil, endpoint: "https://example.test/api", http_client: http_client)

    expect(keyless_client.post_chat(model: "provider/model", messages: [])).to be_nil
  end
end
