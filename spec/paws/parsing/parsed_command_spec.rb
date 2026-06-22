# frozen_string_literal: true

require "spec_helper"

RSpec.describe PAWS::ParsedCommand do
  describe ".from_ai_result" do
    it "normalizes AI parser output into command fields" do
      command = described_class.from_ai_result(
        "verb" => 5,
        "noun1" => 10,
        "noun2" => 0,
        "adject1" => 3,
        "adject2" => 0,
        "adverb" => 2,
        "prep" => 4,
        "quoted_command" => "hola mundo",
      )

      expect(command.verb).to eq(5)
      expect(command.noun1).to eq(10)
      expect(command.noun2).to be_nil
      expect(command.adject1).to eq(3)
      expect(command.adject2).to be_nil
      expect(command.adverb).to eq(2)
      expect(command.prep).to eq(4)
      expect(command.quoted_command).to eq("hola mundo")
    end

    it "rejects non-string quoted commands from AI output" do
      command = described_class.from_ai_result(
        "verb" => 32,
        "noun1" => 50,
        "quoted_command" => 55,
      )

      expect(command.verb).to eq(32)
      expect(command.noun1).to eq(50)
      expect(command.quoted_command).to be_nil
    end

    it "strips blank quoted commands to nil" do
      command = described_class.from_ai_result(
        "verb" => 32,
        "noun1" => 50,
        "quoted_command" => "  ",
      )

      expect(command.quoted_command).to be_nil
    end
  end
end
