# frozen_string_literal: true

require "json"
require_relative "text_decoder"

module PAWS
  module GameData
    # Builds a reviewable character mapping proposal from already-extracted text.
    # The heuristic mode never calls AI: it preserves observed suspicious bytes as
    # glyph tags whose fallback is the same PC/ASCII character seen in the text.
    class CharacterMappingGenerator
      DEFAULT_SUSPECT_CHARS = [
        "@", "#", "$", "%", "&", "\\", "`", "^", "[", "]", "|", "*", "+"
      ].freeze
      ASCII_EQUIVALENTS = {
        "á" => "a", "é" => "e", "í" => "i", "ó" => "o", "ú" => "u",
        "ñ" => "n", "Ñ" => "N",
      }.freeze
      MAX_CONTEXTS_PER_CHAR = 8
      MAX_CORPUS_LINES = 240

      def initialize(client: nil, model: nil, template_loader: nil)
        @client = client
        @model = model
        @template_loader = template_loader
      end

      def generate(game_data, mode: :heuristic)
        corpus = text_corpus(game_data)
        candidates = candidates_from(corpus)
        return heuristic_mapping(candidates) unless mode.to_sym == :ai

        ai_mapping(corpus, candidates)
      end

      def text_corpus(game_data)
        lines = []
        collect_indexed_text(lines, "location", game_data["locations"], "description")
        collect_indexed_text(lines, "message", game_data["messages"])
        collect_indexed_text(lines, "system_message", game_data["system_messages"])
        collect_indexed_text(lines, "object", game_data["objects"], "name")
        collect_indexed_text(lines, "abbreviation", game_data["abbreviations"], "text")
        collect_indexed_text(lines, "vocabulary", game_data["vocabulary"], "word")
        lines
      end

      def candidates_from(corpus)
        observed = Hash.new { |hash, key| hash[key] = { "char" => key.chr, "count" => 0, "contexts" => [] } }

        corpus.each do |entry|
          visible = visible_text(entry.fetch("text"))
          visible.each_char.with_index do |char, index|
            byte = char.ord
            next unless candidate_char?(char, byte, visible, index)

            candidate = observed[byte]
            candidate["count"] += 1
            candidate["contexts"] << context_for(entry, index) if candidate["contexts"].size < MAX_CONTEXTS_PER_CHAR
          end
        end

        observed.sort.to_h { |byte, data| [byte.to_s, data] }
      end

      private

      attr_reader :client, :model, :template_loader

      def heuristic_mapping(candidates)
        candidates.to_h do |byte_text, data|
          [byte_text, heuristic_value(byte_text.to_i, data)]
        end
      end

      def ai_mapping(corpus, candidates)
        raise ArgumentError, "AI mapping generation requires a chat client" unless client
        raise ArgumentError, "AI mapping generation requires a model" if model.to_s.strip.empty?

        body = client.post_chat(
          model: model,
          messages: [
            { role: "system", content: load_template("system") },
            { role: "user", content: ai_user_prompt(corpus, candidates) },
          ],
        )
        mapping = parse_ai_mapping(body)
        normalize_generated_mapping(mapping, candidates)
      end

      def parse_ai_mapping(body)
        content = if body.is_a?(String)
            JSON.parse(body).dig("choices", 0, "message", "content")
          else
            body.dig("choices", 0, "message", "content") || body.dig(:choices, 0, :message, :content)
          end
        raise ArgumentError, "AI mapping generation returned no content" if content.to_s.strip.empty?

        json = content.to_s.strip
        json = json.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
        parsed = JSON.parse(json)
        mapping = parsed["mapping"] || parsed
        raise ArgumentError, "AI mapping generation did not return a JSON object" unless mapping.is_a?(Hash)

        mapping
      rescue JSON::ParserError => e
        raise ArgumentError, "AI mapping generation returned invalid JSON: #{e.message}"
      end

      def normalize_generated_mapping(mapping, candidates)
        allowed_bytes = candidates.keys.to_h { |byte_text| [byte_text.to_i, true] }
        mapping.each_with_object({}) do |(key, value), normalized|
          byte = normalize_key(key)
          next unless byte&.between?(0, 255)
          next unless allowed_bytes[byte]

          data = candidates.fetch(byte.to_s)
          fallback = normalize_ai_value(value)
          fallback = heuristic_value(byte, data) if ai_no_decision?(fallback, data.fetch("char"))
          next unless byte
          next if fallback.empty?

          normalized[byte.to_s] = normalized_mapping_value(byte, fallback)
        end.tap do |normalized|
          candidates.each do |byte_text, data|
            normalized[byte_text] ||= heuristic_value(byte_text.to_i, data)
          end
        end
      end

      def heuristic_value(byte, data)
        char = data.fetch("char")
        return glyph_fallback(byte, char) if symbol_only_contexts?(data)

        TextDecoder::DEFAULT_MAPPING.fetch(char, glyph_fallback(byte, char))
      end

      def symbol_only_contexts?(data)
        contexts = data.fetch("contexts", [])
        return false if contexts.empty?

        contexts.all? do |context|
          text = context.fetch("snippet", "").delete(" \t\r\n")
          !text.empty? && text.each_char.all? { |char| symbol_context_char?(char) }
        end
      end

      def symbol_context_char?(char)
        DEFAULT_SUSPECT_CHARS.include?(char) || char.match?(/[[:punct:]\d]/)
      end

      def normalize_ai_value(value)
        if value.is_a?(Hash)
          return "" if value.key?("contexts") || value.key?("count")

          value = value["value"] ||
            value["replacement"] ||
            value["character"] ||
            value["unicode"] ||
            value["fallback"] ||
            value["char"]
        end

        text = value.to_s
        return text if text.match?(/\A\{glyph:\d+:[^}]*\}\z/i)

        text.each_char.first.to_s
      end

      def normalized_mapping_value(byte, fallback)
        return fallback if fallback.match?(/\A\{glyph:\d+:[^}]*\}\z/i)
        return glyph_fallback(byte, fallback) if ascii_visible_fallback?(fallback)
        return glyph_fallback(byte, fallback) if control_fallback?(fallback)

        fallback
      end

      def ai_no_decision?(fallback, candidate_char)
        fallback_char = glyph_fallback_char(fallback) || fallback
        default = TextDecoder::DEFAULT_MAPPING[candidate_char]
        return false unless default

        fallback_char == candidate_char || fallback_char == ASCII_EQUIVALENTS[default]
      end

      def glyph_fallback_char(value)
        match = value.to_s.match(/\A\{glyph:\d+:([^}]*)\}\z/i)
        match && match[1]
      end

      def normalize_key(key)
        text = key.to_s
        return text.to_i if text.match?(/\A\d+\z/)
        return text.ord if text.length == 1

        nil
      end

      def ascii_visible_fallback?(fallback)
        fallback.length == 1 && fallback.ascii_only? && fallback.ord.between?(32, 126)
      end

      def control_fallback?(fallback)
        fallback.length == 1 && (fallback.ord < 32 || fallback.ord == 127)
      end

      def glyph_fallback(byte, fallback)
        "{glyph:#{byte}:#{fallback}}"
      end

      def collect_indexed_text(lines, label, values, key = nil)
        Array(values).each_with_index do |value, index|
          text = key && value.is_a?(Hash) ? value[key] : text_value(value)
          next if text.to_s.empty?

          lines << { "source" => "#{label}:#{index}", "text" => text.to_s }
        end
      end

      def text_value(value)
        value.is_a?(Hash) ? value["text"] : value
      end

      def visible_text(text)
        text.to_s.gsub(/\{[^}]+\}/, "")
      end

      def candidate_char?(char, byte, text, index)
        return true if DEFAULT_SUSPECT_CHARS.include?(char)
        return true if byte == 127
        return true if char == "-" && embedded_in_word?(text, index)

        false
      end

      def embedded_in_word?(text, index)
        before = text[index - 1]
        after = text[index + 1]
        letter?(before) && letter?(after)
      end

      def letter?(char)
        char.to_s.match?(/[[:alpha:]]/)
      end

      def context_for(entry, index)
        text = visible_text(entry.fetch("text")).gsub(/\s+/, " ").strip
        start = [index - 24, 0].max
        { "source" => entry.fetch("source"), "snippet" => text[start, 64].to_s }
      end

      def ai_user_prompt(corpus, candidates)
        <<~PROMPT
          Generate a character mapping JSON object for this ZX Spectrum PAWS game.

          Candidate bytes:
          #{JSON.pretty_generate(candidates)}

          Text corpus:
          #{corpus.first(MAX_CORPUS_LINES).map { |entry| "#{entry.fetch("source")}: #{entry.fetch("text")}" }.join("\n")}

          Return only JSON in exactly this shape:
          {"mapping":{"35":"é","64":"á"}}

          Use only bytes from the candidate list as keys. Use one intended readable PC/Unicode character as each value. Do not return candidate metadata, counts, contexts, explanations, arrays, or nested objects.
          For common Spanish PAWS conventions, prefer @=á, #=é, $=í, %=ó, &=ú, |=ñ, \\=ñ, [=¡, ]=¿ when the corpus context agrees.
        PROMPT
      end

      def load_template(name)
        return template_loader.call(name) if template_loader

        path = File.expand_path("../../prompts/ai_mapping/#{name}.md", __dir__)
        File.exist?(path) ? File.read(path) : ""
      end
    end
  end
end
