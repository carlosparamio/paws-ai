# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::ClassicParser do
  let(:vocabulary) do
    [
      { "word" => "coger", "id" => 14, "type_id" => 0 },
      { "word" => "rapid", "id" => 2, "type_id" => 1 },
      { "word" => "llave", "id" => 20, "type_id" => 2 },
      { "word" => "caja", "id" => 21, "type_id" => 2 },
      { "word" => "roja", "id" => 3, "type_id" => 3 },
      { "word" => "con", "id" => 4, "type_id" => 4 },
      { "word" => "ella", "id" => 6, "type_id" => 6 },
    ]
  end

  subject(:parser) { described_class.new(vocabulary: vocabulary) }

  it "returns a ParsedCommand from classic vocabulary matches" do
    command = parser.parse("coger llave roja rapid con caja", context: {})

    expect(command).to have_attributes(
      verb: 14,
      noun1: 20,
      noun2: 21,
      adject1: 3,
      adverb: 2,
      prep: 4,
    )
  end

  it "extracts quoted commands for PARSE" do
    command = parser.parse('coger "hola mundo"', context: {})

    expect(command.verb).to eq(14)
    expect(command.quoted_command).to eq("hola mundo")
  end

  it "resolves pronouns through parser context" do
    command = parser.parse(
      "coger ella",
      context: { pronoun_resolver: ->(_id) { { noun1: 30, adject1: 7 } } },
    )

    expect(command.noun1).to eq(30)
    expect(command.adject1).to eq(7)
  end

  it "returns nil for blank or unknown input" do
    expect(parser.parse("", context: {})).to be_nil
    expect(parser.parse("zzzzz", context: {})).to be_nil
  end
end
