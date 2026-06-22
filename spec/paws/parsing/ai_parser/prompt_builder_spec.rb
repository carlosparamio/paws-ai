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
      actions_list: include("Also checks: LIGERO (flag_check)"),
      parse_actions_list: include("- DI DON can re-parse quoted speech through:"),
    )])
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
