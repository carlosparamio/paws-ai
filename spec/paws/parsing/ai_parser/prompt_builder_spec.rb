# frozen_string_literal: true

require "spec_helper"
require "paws/parsing/ai_parser/prompt_builder"

RSpec.describe PAWS::AIPromptBuilder do
  let(:warnings) { [] }
  let(:template_calls) { [] }
  let(:template_loader) do
    lambda do |name, variables = {}|
      template_calls << [name, variables]
      name == "system" ? "system prompt" : [
        "command=#{variables[:input]}",
        variables[:visible_objects],
        variables[:vocab_list],
        variables[:intent_index],
        variables[:actions_list],
        variables[:parse_actions_list],
      ].join("\n")
    end
  end

  let(:context) do
    {
      game_title: "Test Game",
      location: "Hall",
      inventory: ["lamp"],
      history: ["You are here."],
      visible_objects: ["Don está aquí."],
      vocabulary: [
        { id: 10, word: "TOMA", type: 0 },
        { id: 20, word: "ANILL", type: 2 },
        { id: 32, word: "DI", type: 0 },
        { id: 25, word: "DON", type: 2 },
        { id: 59, word: "VEN", type: 0 },
        { id: 40, word: "CON", type: 4 },
        { id: 50, word: "LIGERO", type: 3 },
        { id: 60, word: "RAPID", type: 1 },
      ],
      response_table: [
        { verb: "TOMA", noun: "ANILL", checks: [{ word: "LIGERO", type: "flag_check" }] },
      ],
      parse_response_table: [
        {
          verb: "DI",
          noun: "DON",
          processes: [
            {
              id: 6,
              entries: [
                { verb: "VEN", noun: "_", verb_aliases: ["VEN", "SIGUE"], noun_aliases: ["_"], checks: [] },
              ],
            },
          ],
        },
      ],
      intent_index: [
        {
          verb: "TOMA",
          noun: "ANILL",
          verb_aliases: ["TOMA"],
          noun_aliases: ["ANILL"],
          checks: [{ type: "adjective1", word: "LIGERO", aliases: ["LIGERO"], id: 50 }],
        },
        {
          verb: "TOMA",
          noun: "_",
          verb_aliases: ["TOMA"],
          noun_aliases: ["_"],
          checks: [{ type: "adverb", word: "RAPID", aliases: ["RAPID"], id: 60 }],
        },
      ],
      is_nested: false,
    }
  end

  subject(:builder) do
    described_class.new(template_loader: template_loader, warn: ->(message) { warnings << message })
  end

  it "builds non-empty OpenAI-compatible messages from context" do
    payload = builder.request_payload("toma anillo", context, model: "test/model")

    expect(payload[:model]).to eq("test/model")
    expect(payload[:messages]).to match([
      { role: "system", content: "system prompt" },
      { role: "user", content: include("command=toma anillo", "- Don está aquí.", "- DI DON can re-parse quoted speech through:", "  - VEN/SIGUE _") },
    ])
    expect(template_calls).to include(["normal_mode", hash_including(
      vocab_list: include(" 20: ANILL           [noun]"),
      intent_index: start_with("[\n"),
      actions_list: include("Also checks: LIGERO (flag_check)"),
      parse_actions_list: include("- DI DON can re-parse quoted speech through:"),
    )])
  end

  def intent_index_json(context_override = {})
    builder.request_payload("input", context.merge(context_override), model: "test/model")
    call = template_calls.find { |name, _| name == "normal_mode" }
    JSON.parse(call[1][:intent_index])
  end

  it "renders the intent index as a JSON array that mirrors the output schema" do
    parsed = intent_index_json

    expect(parsed).to be_an(Array)

    expect(parsed[0]).to eq(
      "verb"    => "TOMA",
      "noun1"   => "ANILL",
      "adject1" => ["LIGERO"],
      "adject2" => [],
      "noun2"   => [],
      "adverb"  => [],
      "prep"    => [],
    )

    expect(parsed[1]).to eq(
      "verb"    => "TOMA",
      "noun1"   => "_",
      "adject1" => [],
      "adject2" => [],
      "noun2"   => [],
      "adverb"  => ["RAPID"],
      "prep"    => [],
    )
  end

  it "fills every check slot in the intent index (adjective1, adjective2, noun2, adverb, preposition)" do
    parsed = intent_index_json(intent_index: [
      {
        verb: "ATA",
        noun: "GUARDI",
        verb_aliases: ["ATA", "GOLP"],
        noun_aliases: ["GUARDI"],
        checks: [
          { type: "adjective1", word: "MALO", aliases: ["MALO"], id: 70 },
          { type: "adjective2", word: "ENOJADO", aliases: ["ENOJADO"], id: 73 },
          { type: "adverb", word: "FURI", aliases: ["FURI"], id: 71 },
          { type: "preposition", word: "CON", aliases: ["CON"], id: 40 },
          { type: "noun", word: "ARMA", aliases: ["ARMA"], id: 72 },
        ],
      },
    ])

    expect(parsed.first).to eq(
      "verb"    => "ATA/GOLP",
      "noun1"   => "GUARDI",
      "adject1" => ["MALO"],
      "adject2" => ["ENOJADO"],
      "noun2"   => ["ARMA"],
      "adverb"  => ["FURI"],
      "prep"    => ["CON"],
    )
  end

  it "merges repeated checks into a single deduped array per slot" do
    parsed = intent_index_json(intent_index: [
      {
        verb: "METE",
        noun: "TODO",
        verb_aliases: ["METE"],
        noun_aliases: ["TODO"],
        checks: [
          { type: "noun", word: "BOTE", aliases: ["BOTE"], id: 63 },
          { type: "noun", word: "APARA", aliases: ["APARA"], id: 55 },
          { type: "noun", word: "BOTE", aliases: ["BOTE"], id: 63 }, # repeated
          { type: "preposition", word: "EN", aliases: ["EN"], id: 41 },
          { type: "preposition", word: "EN", aliases: ["EN"], id: 41 }, # repeated
        ],
      },
    ])

    expect(parsed.first).to eq(
      "verb"    => "METE",
      "noun1"   => "TODO",
      "adject1" => [],
      "adject2" => [],
      "noun2"   => ["BOTE", "APARA"],
      "adverb"  => [],
      "prep"    => ["EN"],
    )
  end

  it "renders an empty intent index as a JSON empty array" do
    builder.request_payload("look", context.merge(intent_index: []), model: "test/model")
    call = template_calls.find { |name, _| name == "normal_mode" }

    expect(call[1][:intent_index]).to eq("[]")
    expect(JSON.parse(call[1][:intent_index])).to eq([])
  end

  it "renders the bundled prompt with the intent index wrapped in a JSON code block" do
    real_builder = described_class.new(
      template_loader: ->(_name, _vars = {}) { File.read("lib/paws/prompts/ai_parser/normal_mode.md").gsub("{{game_title}}", "T").gsub("{{location}}", "L").gsub("{{inventory}}", "").gsub("{{visible_objects}}", "").gsub("{{history}}", "").gsub("{{vocab_list}}", "").gsub("{{intent_index}}", "[]").gsub("{{input}}", "x").gsub("{{di_id}}", "32").gsub("{{preg_id}}", "33").gsub("{{actions_list}}", "").gsub("{{parse_actions_list}}", "") },
      warn: ->(_msg) {},
    )
    payload = real_builder.request_payload("x", context.merge(intent_index: []), model: "test/model")
    rendered = payload[:messages].last[:content]

    expect(rendered).to match(/```json\n\[\]\n```/)
  end

  it "returns nil and warns when the rendered user prompt is empty" do
    empty_builder = described_class.new(
      template_loader: ->(_name, _variables = {}) { "" },
      warn: ->(message) { warnings << message },
    )

    expect(empty_builder.request_payload("look", context, model: "test/model")).to be_nil
    expect(warnings).to include("AI Parser Prompt Error: user prompt is empty")
  end
end
