# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe PAWS::EnvLoader do
  it "loads key value pairs without overriding existing environment values" do
    file = Tempfile.new("paws-env")
    file.write(<<~ENV_FILE)
      # comment
      AI_PARSER_API_KEY=from-file
      export AI_PARSER_ENDPOINT="https://example.test/api"
      AI_PARSER_MODEL='provider/model'
    ENV_FILE
    file.close
    env = { "AI_PARSER_API_KEY" => "already-exported" }

    described_class.load(file.path, env: env)

    expect(env).to include(
      "AI_PARSER_API_KEY" => "already-exported",
      "AI_PARSER_ENDPOINT" => "https://example.test/api",
      "AI_PARSER_MODEL" => "provider/model",
    )
  ensure
    file.unlink if file
  end
end
