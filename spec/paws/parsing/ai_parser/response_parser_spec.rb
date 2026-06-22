# frozen_string_literal: true

require "spec_helper"
require "paws/parsing/ai_parser/response_parser"

RSpec.describe PAWS::AIResponseParser do
  let(:warnings) { [] }
  let(:logs) { [] }

  subject(:parser) do
    described_class.new(
      logger: ->(message, level) { logs << [message, level] },
      warn: ->(message) { warnings << message },
    )
  end

  it "parses JSON content and strips Markdown fences" do
    body = {
      "choices" => [
        { "message" => { "content" => "```json\n{\"verb\": 10, \"noun1\": 20}\n```" } },
      ],
    }

    expect(parser.parse(body)).to eq({ "verb" => 10, "noun1" => 20 })
    expect(logs.first.last).to eq(3)
  end

  it "accepts reasoning when content is absent" do
    body = {
      "choices" => [
        { "message" => { "reasoning" => '{"verb": 32, "noun1": 25}' } },
      ],
    }

    expect(parser.parse(body)).to eq({ "verb" => 32, "noun1" => 25 })
  end

  it "returns nil and warns when there is no parseable content" do
    expect(parser.parse({ "choices" => [{ "message" => {} }] })).to be_nil
    expect(warnings.first).to include("No content/reasoning")
  end

  it "returns nil and warns when model content is not a JSON object" do
    body = {
      "choices" => [
        { "message" => { "content" => '[{"verb": 10}]' } },
      ],
    }

    expect(parser.parse(body)).to be_nil
    expect(warnings.first).to include("expected an object")
  end
end
