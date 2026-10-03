# frozen_string_literal: true

require "spec_helper"
require "paws/parsing/ai_parser"
require "faraday"

RSpec.describe PAWS::AIParser do
  let(:api_key) { "fake_key" }
  let(:endpoint) { "https://example.test/api" }
  let(:model) { "provider/model" }
  let(:input) { "toma el anillo" }
  let(:template_calls) { [] }
  let(:template_loader) do
    lambda do |name, variables = {}|
      template_calls << [name, variables]
      "System prompt\n{{input}}\n{{vocab_list}}"
    end
  end
  let(:context) do
    {
      game_title: "Test Game",
      location: "Start Room",
      inventory: ["item1"],
      history: ["You enter the room."],
      vocabulary: [
        { id: 10, word: "TOMA", type: 0 },
        { id: 20, word: "ANILL", type: 2 },
      ],
      response_table: [],
      intent_index: [],
      is_nested: false,
    }
  end

  before do
    # Template IO is injected so these specs do not depend on prompt files.
  end

  describe "#parse" do
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }
    let(:conn) { Faraday.new { |b| b.adapter(:test, stubs) } }
    subject(:parser) do
      described_class.new(
        api_key: api_key,
        endpoint: endpoint,
        model: model,
        http_client: conn,
        template_loader: template_loader,
      )
    end

    before do
      allow(Faraday).to receive(:new).and_return(conn)
    end

    it "returns a ParsedCommand on success" do
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end

      result = parser.parse(input, context: context)
      expect(result).to have_attributes(verb: 10, noun1: 20)
    end

    it "handles markdown JSON blocks" do
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: "```json\n{\"verb\": 10, \"noun1\": 20}\n```" } }],
        }.to_json]
      end

      result = parser.parse(input, context: context)
      expect(result).to have_attributes(verb: 10, noun1: 20)
    end

    it "returns nil on API error" do
      stubs.post("/chat/completions") { [500, {}, "Error"] }

      # Silence warning for test
      allow(parser).to receive(:warn)

      expect(parser.parse(input, context: context)).to be_nil
    end

    it "returns nil on invalid JSON response" do
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: "invalid json" } }],
        }.to_json]
      end

      allow(parser).to receive(:warn)

      expect(parser.parse(input, context: context)).to be_nil
    end

    it "returns nil on empty content response" do
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: {} }],
        }.to_json]
      end

      allow(parser).to receive(:warn)

      expect(parser.parse(input, context: context)).to be_nil
    end

    it "returns nil on connection error" do
      allow(conn).to receive(:post).and_raise(Faraday::ConnectionFailed.new("Connection failed"))

      allow(parser).to receive(:warn)

      expect(parser.parse(input, context: context)).to be_nil
    end

    it "requires API key configuration" do
      expect do
        described_class.new(api_key: nil, endpoint: endpoint, model: model, http_client: conn, template_loader: template_loader)
      end.to raise_error(ArgumentError, /AI_PARSER_API_KEY/)
    end

    it "honors explicit API configuration over configured environment values" do
      configuration = PAWS::AIParserConfiguration.new(
        api_key: "configured-key",
        endpoint: "https://configured.test/api",
        model: "configured/model",
      )
      prompt_builder = instance_double(
        PAWS::AIPromptBuilder,
        request_payload: { model: "override/model", messages: [] },
      )
      client = instance_double(PAWS::OpenAIChatClient, post_chat: { "choices" => [] })
      response_parser = instance_double(PAWS::AIResponseParser)
      parser = described_class.new(
        configuration: configuration,
        api_key: "override-key",
        endpoint: "https://override.test/api",
        model: "override/model",
        prompt_builder: prompt_builder,
        client: client,
        response_parser: response_parser,
      )

      expect(response_parser).to receive(:parse).with({ "choices" => [] })
      parser.parse(input, context: context)
    end

    it "formats vocabulary list correctly" do
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end

      expected_vocab_list = " 10: TOMA            [verb]\n 20: ANILL           [noun]"

      parser.parse(input, context: context)

      expect(template_calls).to include(["normal_mode", hash_including(vocab_list: expected_vocab_list)])
    end

    it "executes Faraday initialization block and constructs prompt with different vocab types and response table checks" do
      # 1. Faraday init block coverage
      allow(Faraday).to receive(:new).and_call_original
      parser = described_class.new(api_key: api_key, endpoint: "https://example.test/api", model: model, template_loader: template_loader)
      allow(parser).to receive(:warn)

      custom_context = context.merge({
        vocabulary: [
          { id: 10, word: "TOMA", type: 0 },
          { id: 11, word: "RAPID", type: 1 },
          { id: 20, word: "ANILL", type: 2 },
          { id: 30, word: "ROJO", type: 3 },
          { id: 40, word: "CON", type: 4 },
          { id: 50, word: "OTRO", type: 5 },
        ],
        response_table: [
          { verb: "TOMA", noun: "ANILL", checks: [{ word: "LIGERO", type: "flag_check" }] },
        ],
        intent_index: [],
      })

      expect(parser.parse(input, context: custom_context)).to be_nil
    end

    it "sends non-empty OpenAI-compatible message content" do
      captured_body = nil
      stubs.post("/chat/completions") do |env|
        captured_body = env.body.is_a?(String) ? JSON.parse(env.body) : env.body
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end

      parser.parse(input, context: context)

      messages = captured_body["messages"] || captured_body[:messages]
      contents = messages.map { |message| message["content"] || message[:content] }

      expect(contents).to all(satisfy { |content| !content.strip.empty? })
    end

    it "logs the AI request payload at verbosity level 3" do
      logs = []
      parser = described_class.new(
        api_key: api_key,
        endpoint: endpoint,
        model: model,
        http_client: conn,
        template_loader: template_loader,
        logger: ->(message, level) { logs << [message, level] },
      )
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end

      parser.parse(input, context: context)

      expect(logs).to include([include("AI request payload"), 3])
    end

    it "uses an externally configurable endpoint" do
      old_endpoint = ENV["AI_PARSER_ENDPOINT"]
      ENV["AI_PARSER_ENDPOINT"] = "https://example.test/api"
      stubs.post("/chat/completions") do
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end
      expect(Faraday).to receive(:new).with(url: "https://example.test/api").and_return(conn)
      parser = described_class.new(api_key: api_key, endpoint: "https://example.test/api", model: model, template_loader: template_loader)

      parser.parse(input, context: context)
    ensure
      ENV["AI_PARSER_ENDPOINT"] = old_endpoint
    end

    it "does not call the API when the rendered user prompt is empty" do
      empty_template_loader = ->(_name, _variables = {}) { "" }
      parser = described_class.new(api_key: api_key, endpoint: endpoint, model: model, http_client: conn, template_loader: empty_template_loader)
      allow(parser).to receive(:warn)

      expect(parser.parse(input, context: context)).to be_nil
      expect(parser).to have_received(:warn).with(/user prompt is empty/)
    end

    it "loads bundled prompt templates when no template loader is injected" do
      captured_body = nil
      stubs.post("/chat/completions") do |env|
        captured_body = env.body.is_a?(String) ? JSON.parse(env.body) : env.body
        [200, { "Content-Type" => "application/json" }, {
          choices: [{ message: { content: '{"verb": 10, "noun1": 20}' } }],
        }.to_json]
      end
      parser = described_class.new(api_key: api_key, endpoint: endpoint, model: model, http_client: conn)

      parser.parse(input, context: context)

      messages = captured_body["messages"] || captured_body[:messages]
      contents = messages.map { |message| message["content"] || message[:content] }
      expect(contents.join("\n")).to include("MANDATORY OUTPUT FORMAT")
      expect(contents.join("\n")).to include("NORMAL MODE")
      expect(contents.join("\n")).to include('User command: "toma el anillo"')
    end
  end

  describe "collaborator orchestration" do
    it "coordinates prompt, chat transport, and response parsing behind a ParsedCommand facade" do
      payload = { model: "provider/model", messages: [{ role: "user", content: "prompt" }] }
      prompt_builder = instance_double(PAWS::AIPromptBuilder, request_payload: payload)
      client = instance_double(PAWS::OpenAIChatClient, post_chat: { "raw" => true })
      response_parser = instance_double(PAWS::AIResponseParser, parse: { "verb" => 10, "noun1" => 20 })
      parser = described_class.new(
        api_key: api_key,
        endpoint: endpoint,
        model: "provider/model",
        prompt_builder: prompt_builder,
        client: client,
        response_parser: response_parser,
      )

      result = parser.parse(input, context: context)

      expect(result).to have_attributes(verb: 10, noun1: 20)
      expect(prompt_builder).to have_received(:request_payload).with(input, context, model: "provider/model")
      expect(client).to have_received(:post_chat).with(payload)
      expect(response_parser).to have_received(:parse).with({ "raw" => true })
    end
  end
end
