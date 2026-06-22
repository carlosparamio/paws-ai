# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::GameData::CharacterMappingGenerator do
  subject(:generator) { described_class.new }

  it "generates a heuristic glyph mapping for suspicious observed bytes" do
    game_data = {
      "locations" => [{ "description" => "Est@s en m-sica." }],
      "messages" => ["HAS +IDO AQUI"],
      "system_messages" => ["No veo nada."],
      "objects" => [{ "name" => "llave" }],
      "vocabulary" => [{ "word" => "COGE" }],
    }

    mapping = generator.generate(game_data)

    expect(mapping).to include(
      "43" => "{glyph:43:+}",
      "45" => "{glyph:45:-}",
      "64" => "á",
    )
    expect(mapping).not_to have_key("67")
  end

  it "does not treat editorial hyphens as mapping candidates" do
    game_data = {
      "messages" => ["TRANS- FERIDO", "PASA - NADA"],
    }

    expect(generator.generate(game_data)).not_to have_key("45")
  end

  it "keeps symbol-only suspicious characters as glyph fallbacks" do
    game_data = {
      "messages" => ["{1}{ink:red}$%"],
    }

    expect(generator.generate(game_data)).to include(
      "36" => "{glyph:36:$}",
      "37" => "{glyph:37:%}",
    )
  end

  it "can normalize an AI mapping response while preserving ASCII fallbacks as glyph tags" do
    client = instance_double(
      PAWS::OpenAIChatClient,
      post_chat: {
        "choices" => [
          {
            "message" => {
              "content" => '{"mapping":{"64":"á","45":"-"}}',
            },
          },
        ],
      },
    )
    ai_generator = described_class.new(client: client, model: "provider/model")
    game_data = { "locations" => [{ "description" => "Est@s en m-sica." }] }

    mapping = ai_generator.generate(game_data, mode: :ai)

    expect(mapping).to include(
      "64" => "á",
      "45" => "{glyph:45:-}",
    )
    expect(client).to have_received(:post_chat).with(
      hash_including(
        model: "provider/model",
        messages: include(hash_including(role: "system"), hash_including(role: "user")),
      ),
    )
  end

  it "ignores AI metadata echoes and keys outside the observed candidates" do
    client = instance_double(
      PAWS::OpenAIChatClient,
      post_chat: {
        "choices" => [
          {
            "message" => {
              "content" => '{"mapping":{"64":{"char":"@","count":3,"contexts":[]},"999":"x"}}',
            },
          },
        ],
      },
    )
    ai_generator = described_class.new(client: client, model: "provider/model")
    game_data = { "locations" => [{ "description" => "Est@s." }] }

    mapping = ai_generator.generate(game_data, mode: :ai)

    expect(mapping).to eq("64" => "á")
  end
end
