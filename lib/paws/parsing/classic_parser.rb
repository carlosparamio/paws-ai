# frozen_string_literal: true

require_relative "parsed_command"

module PAWS
  # Deterministic PAWS vocabulary parser.
  # It converts player text into ParsedCommand using the original five-character vocabulary rules,
  # while Engine decides when to use it and how to store the result in flags.
  class ClassicParser
    def initialize(vocabulary: nil, vocabulary_lookup: nil)
      @vocabulary = vocabulary || []
      @vocabulary_lookup = vocabulary_lookup
    end

    def parse(input, context:)
      return nil if input.nil? || input.strip.empty?

      input = input.dup
      quoted_command = extract_quoted_command(input)
      input = input[0...input.index('"')] if input.index('"')

      command = parse_words(words_for(input), context) || {}
      return nil if command.empty? && quoted_command.nil?

      ParsedCommand.new(
        verb: command[:verb],
        noun1: command[:noun1],
        noun2: command[:noun2],
        adject1: command[:adject1],
        adject2: command[:adject2],
        adverb: command[:adverb],
        prep: command[:prep],
        quoted_command: quoted_command,
      )
    end

    private

    def extract_quoted_command(input)
      return nil unless (idx = input.index('"'))

      input[idx + 1..].sub(/"$/, "")
    end

    def words_for(input)
      input.strip.downcase.gsub(/[[:punct:]]/, " ").split(/\s+/)
    end

    def parse_words(words, context)
      command = {}

      words.each do |word|
        entry = find_vocabulary(word)
        next unless entry

        apply_entry(command, entry, context)
      end

      command.empty? ? nil : command
    end

    def find_vocabulary(word)
      return @vocabulary_lookup.call(word) if @vocabulary_lookup

      word = word[0, 5]
      @vocabulary.find { |entry| entry["word"].downcase == word }
    end

    def apply_entry(command, entry, context)
      case entry["type_id"]
      when 0
        command[:verb] ||= entry["id"]
      when 1
        command[:adverb] ||= entry["id"]
      when 2
        assign_noun(command, entry["id"])
      when 3
        assign_adjective(command, entry["id"])
      when 4
        command[:prep] ||= entry["id"]
      when 6
        apply_pronoun(command, entry["id"], context)
      end
    end

    def assign_noun(command, id)
      if command[:noun1].nil?
        command[:noun1] = id
      else
        command[:noun2] ||= id
      end
    end

    def assign_adjective(command, id)
      if command[:adject1].nil?
        command[:adject1] = id
      else
        command[:adject2] ||= id
      end
    end

    def apply_pronoun(command, id, context)
      resolver = context[:pronoun_resolver]
      return unless resolver

      resolved = resolver.call(id) || {}
      command[:noun1] = resolved[:noun1] if resolved.key?(:noun1)
      command[:adject1] = resolved[:adject1] if resolved.key?(:adject1)
    end
  end
end
