# frozen_string_literal: true

require "spec_helper"
require "paws/game_data/adventure_translator"

RSpec.describe PAWS::GameData::AdventureTranslator do
  class FakeTranslationClient
    attr_reader :payloads

    def initialize(*responses)
      @responses = responses
      @payloads = []
    end

    def post_chat(payload)
      @payloads << payload
      content = @responses.shift || {}
      { "choices" => [{ "message" => { "content" => JSON.generate(content) } }] }
    end
  end

  let(:game_data) do
    {
      "locations" => [
        { "id" => 0, "description" => "Pantalla de titulo" },
        { "id" => 1, "description" => "{ink:red}Ves un muro_." },
      ],
      "messages" => [
        "No ves nada especial.",
        "El muro no se mueve.",
      ],
      "system_messages" => [
        "Esta oscuro.",
        "Tambien puedes ver:",
        ">",
      ],
      "objects" => [
        { "id" => 0, "name" => "Una llave.", "noun_id" => 20, "adjective_id" => 255 },
      ],
      "vocabulary" => [
        { "word" => "MIRAR", "id" => 10, "type" => "verb", "type_id" => 0 },
        { "word" => "MURO", "id" => 20, "type" => "noun", "type_id" => 2 },
        { "word" => "ROJO", "id" => 30, "type" => "adjective", "type_id" => 3 },
      ],
      "connections" => [[1, [[2, 2]]]],
      "processes" => [
        {
          "id" => 0,
          "entries" => [
            {
              "verb" => 10,
              "verb_name" => "MIRAR",
              "noun" => 20,
              "noun_name" => "MURO",
              "condacts" => [
                { "name" => "AT", "params" => [1] },
                { "name" => "MESSAGE", "params" => [1] },
                { "name" => "NOUN2", "params" => [20] },
                { "name" => "DONE", "params" => [] },
              ],
            },
          ],
        },
      ],
    }
  end

  def translator(client)
    described_class.new(
      client: client,
      model: "test/model",
      source_language: "es",
      target_language: "en",
    )
  end

  it "analyzes process text, location, object, and vocabulary dependencies" do
    analysis = translator(FakeTranslationClient.new).analyze(game_data)

    expect(analysis[:process_text_refs]).to include(hash_including(
      process_id: 0,
      condact: "MESSAGE",
      target: :messages,
      id: 1,
      locations: [1],
    ))
    expect(analysis[:clusters][1][:message_ids]).to include(1)
    expect(analysis[:clusters][1][:vocabulary_ids]).to include("0:10", "2:20")
  end

  it "translates batches and preserves vocabulary schema without adding aliases" do
    client = FakeTranslationClient.new(
      { "glossary" => { "wall" => "WALL" } },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [
          { "id" => 0, "name" => "A key." },
        ],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a wall_.")
    expect(result["messages"][1]).to eq("The wall does not move.")
    expect(result["objects"][0]["name"]).to eq("A key.")
    expect(result["processes"][0]["entries"][0]["condacts"][1]["params"]).to eq([1])
    expect(result["processes"][0]["entries"][0]["verb"]).to eq(10)
    expect(result["processes"][0]["entries"][0]["verb_name"]).to eq("LOOK")
    expect(result["processes"][0]["entries"][0]["noun_name"]).to eq("WALL")

    vocab_words = result["vocabulary"].map { |entry| [entry["type_id"], entry["id"], entry["word"]] }
    expect(result["vocabulary"].length).to eq(game_data["vocabulary"].length)
    expect(vocab_words).to include([0, 10, "LOOK"], [2, 20, "WALL"])
    expect(vocab_words).not_to include([0, 10, "MIRAR"], [0, 10, "L"], [0, 10, "M"])
  end

  it "normalizes model responses that echo batch item metadata" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "kind" => "locations", "id" => 0, "key" => "description", "text" => "Title screen" },
          { "kind" => "locations", "id" => 1, "key" => "description", "text" => "{ink:red}You see a wall_." },
        ],
        "messages" => [
          { "kind" => "messages", "id" => 0, "key" => "text", "text" => "You see nothing special." },
          { "kind" => "messages", "id" => 1, "key" => "text", "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "kind" => "system_messages", "id" => 0, "key" => "text", "text" => "It is dark." },
          { "kind" => "system_messages", "id" => 1, "key" => "text", "text" => "You can also see:" },
          { "kind" => "system_messages", "id" => 2, "key" => "text", "text" => ">" },
        ],
        "objects" => [
          { "kind" => "objects", "id" => 0, "key" => "name", "text" => "A key." },
        ],
        "vocabulary" => [
          { "kind" => "vocabulary", "index" => 0, "key" => "word", "text" => "LOOK" },
          { "kind" => "vocabulary", "index" => 1, "key" => "word", "text" => "WALL" },
          { "kind" => "vocabulary", "index" => 2, "key" => "word", "text" => "RED" },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a wall_.")
    expect(result["objects"][0]["name"]).to eq("A key.")
    expect(result["vocabulary"][0]["word"]).to eq("LOOK")
  end

  it "normalizes translated vocabulary stems and ignores echoed vocabulary metadata" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "examine", "type_id" => 0 },
          { "index" => 1, "word" => "WALL", "type_id" => 2 },
          { "index" => 2, "word" => "RED", "type_id" => 3 },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["vocabulary"][0]["word"]).to eq("EXAMI")
  end

  it "protects direction words and skips vocabulary translations that collide with another id" do
    data = JSON.parse(JSON.generate(game_data))
    data["vocabulary"] << { "word" => "N", "id" => 2, "type" => "noun", "type_id" => 2 }
    data["vocabulary"] << { "word" => "PARED", "id" => 31, "type" => "noun", "type_id" => 2 }
    data["vocabulary"] << { "word" => "O", "id" => 4, "type" => "noun", "type_id" => 2 }
    data["connections"] << [2, [[4, 1]]]
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
          { "index" => 3, "word" => "NORTH" },
          { "index" => 4, "word" => "WALL" },
          { "index" => 5, "word" => "W" },
        ],
      },
    )

    result = translator(client).translate(data)

    expect(result["vocabulary"][3]["word"]).to eq("N")
    expect(result["vocabulary"][4]["word"]).to eq("PARED")
    expect(result["vocabulary"][5]["word"]).to eq("W")
  end

  it "ignores translated entries that were sent as context but not requested in the batch" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 999, "description" => "Unexpected extra location" },
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["locations"].length).to eq(2)
    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a wall_.")
  end

  it "preserves leading control tags even when the model drops them" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "You see a wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a wall_.")
  end

  it "rejects translations that drop underscore placeholders" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a wall." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    expect do
      translator(client).translate(game_data)
    end.to raise_error(ArgumentError, /underscore/)
  end

  it "allows translated prose to drop source glyph placeholders when they are no longer needed" do
    data = game_data
    data["locations"][1]["description"] = "{ink:red}Ves un peque{glyph:124:ñ}o muro_."
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a small wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    result = translator(client).translate(data)

    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a small wall_.")
  end

  it "renders model glyph placeholders to their visible fallback" do
    client = FakeTranslationClient.new(
      { "glossary" => {} },
      {
        "locations" => [
          { "id" => 0, "description" => "Title screen" },
          { "id" => 1, "description" => "{ink:red}You see a {glyph:99:x}wall_." },
        ],
        "messages" => [
          { "id" => 0, "text" => "You see nothing special." },
          { "id" => 1, "text" => "The wall does not move." },
        ],
        "system_messages" => [
          { "id" => 0, "text" => "It is dark." },
          { "id" => 1, "text" => "You can also see:" },
          { "id" => 2, "text" => ">" },
        ],
        "objects" => [{ "id" => 0, "name" => "A key." }],
        "vocabulary" => [
          { "index" => 0, "word" => "LOOK" },
          { "index" => 1, "word" => "WALL" },
          { "index" => 2, "word" => "RED" },
        ],
      },
    )

    result = translator(client).translate(game_data)

    expect(result["locations"][1]["description"]).to eq("{ink:red}You see a xwall_.")
  end
end
