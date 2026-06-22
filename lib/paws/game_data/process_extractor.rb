# frozen_string_literal: true

require_relative "condact_metadata"

module PAWS
  module GameData
    # Extracts PAWS process tables and condact bytecode from snapshot memory.
    # This class is the bytecode/table Strategy for Extractor: it understands
    # process entries, vocabulary labels used for debug-friendly JSON, and
    # condact arity metadata. Text, object, and location tables stay outside its
    # boundary.
    class ProcessExtractor
      NO_WORD = 255
      WILDCARD_STAR = 1
      DIRECTION_FALLBACK_RANGE = 0...20
      CONDACT_TERMINATOR = 255
      PROCESS_TERMINATOR = 0

      attr_reader :verb_vocab, :noun_vocab

      def initialize(sna:, vocabulary:, verb_vocab: nil, noun_vocab: nil)
        @sna = sna
        @verb_vocab = verb_vocab || {}
        @noun_vocab = noun_vocab || {}
        build_vocabulary_lookup(vocabulary) unless verb_vocab || noun_vocab
      end

      def extract(off_pro, num_pro)
        processes = []
        num_pro.times do |index|
          pro_ptr = sna.peek_word(off_pro + index * 2)
          next unless pro_ptr

          processes << { "id" => index, "entries" => extract_entries(pro_ptr) }
        end
        processes
      end

      def resolve_vocab(value, type)
        return "_" if value == NO_WORD
        return "*" if value == WILDCARD_STAR

        name = case type
          when :verb then verb_vocab[value]
          when :noun then noun_vocab[value]
          end

        return fallback_name(value) if name.nil? && [:verb, :noun].include?(type)

        name || value.to_s
      end

      def extract_condacts(ptr)
        return [] unless ptr

        condacts = []
        safety = 0

        while safety < 100
          byte = sna.peek(ptr)
          break if byte == CONDACT_TERMINATOR

          condact_def = CondactMetadata.fetch(byte)
          if condact_def
            params = condact_params(ptr, condact_def)
            condacts << { opcode: byte, name: condact_def[:name], params: params }
            ptr += 1 + condact_def[:params]
          else
            condacts << { opcode: byte, name: "UNKNOWN_#{byte}", params: [] }
            ptr += 1
          end

          safety += 1
        end

        condacts
      end

      private

      attr_reader :sna

      def build_vocabulary_lookup(vocabulary)
        vocabulary&.each do |entry|
          case entry["type_id"]
          when 0 then verb_vocab[entry["id"]] ||= entry["word"]
          when 2 then noun_vocab[entry["id"]] ||= entry["word"]
          end
        end
      end

      def extract_entries(pro_ptr)
        entries = []
        safety = 0
        while sna.peek(pro_ptr) != PROCESS_TERMINATOR && safety < 500
          entries << extract_entry(pro_ptr)
          pro_ptr += 4
          safety += 1
        end
        merge_unconditional_message_continuations(entries)
      end

      def extract_entry(pro_ptr)
        verb = sna.peek(pro_ptr)
        noun = sna.peek(pro_ptr + 1)
        condact_ptr = sna.peek_word(pro_ptr + 2)

        {
          "verb" => verb,
          "verb_name" => resolve_vocab(verb, :verb),
          "noun" => noun,
          "noun_name" => resolve_vocab(noun, :noun),
          "condacts" => extract_condacts(condact_ptr),
        }
      end

      def condact_params(ptr, condact_def)
        params = []
        condact_def[:params].times do |index|
          params << sna.peek(ptr + 1 + index)
        end
        params
      end

      def merge_unconditional_message_continuations(entries)
        normalized = []

        entries.each do |entry|
          if message_continuation?(entry)
            merged = append_continuation_to_previous_matches(normalized, entry)
            next if merged
          end

          normalized << entry
        end

        normalized
      end

      def message_continuation?(entry)
        condacts = entry["condacts"] || []
        return false unless condacts.size == 1

        condact_name(condacts.first) == "MESSAGE"
      end

      def append_continuation_to_previous_matches(entries, continuation)
        targets = []

        entries.reverse_each do |entry|
          break unless entry["verb"] == continuation["verb"] && entry["noun"] == continuation["noun"]
          break if entry_done?(entry)

          targets << entry
        end

        return false if targets.empty?

        targets.each do |entry|
          entry["condacts"] += deep_copy_condacts(continuation["condacts"])
        end
        true
      end

      def entry_done?(entry)
        (entry["condacts"] || []).any? { |condact| condact_name(condact) == "DONE" }
      end

      def condact_name(condact)
        condact[:name] || condact["name"]
      end

      def deep_copy_condacts(condacts)
        condacts.map(&:dup)
      end

      def fallback_name(value)
        return "*" if DIRECTION_FALLBACK_RANGE.cover?(value)

        "_"
      end
    end
  end
end
