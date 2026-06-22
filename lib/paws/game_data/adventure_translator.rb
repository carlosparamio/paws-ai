# frozen_string_literal: true

require "json"
require "set"
require_relative "../utils/text_markup"

module PAWS
  module GameData
    # Translates extracted PAWS game_data while preserving the runtime schema.
    # The model only returns small JSON fragments; this service validates and
    # merges them so bytecode, ids, connections, graphics, and counters remain
    # under local control.
    class AdventureTranslator
      TEXT_CONDACTS = {
        "MESSAGE" => :messages,
        "MES" => :messages,
        "PRINT" => :messages,
        "SYSMESS" => :system_messages,
        "LISTAT" => :locations,
      }.freeze

      LOCATION_CONDACTS = %w[AT NOTAT ATGT ATLT GOTO LISTAT].freeze
      OBJECT_CONDACTS = %w[PRESENT ABSENT WORN NOTWORN CARRIED NOTCARR GET DROP WEAR REMOVE DESTROY CREATE].freeze
      VOCAB_CONDACTS = {
        "ADJECT1" => 3,
        "ADJECT2" => 3,
        "ADVERB" => 1,
        "PREP" => 4,
        "NOUN2" => 2,
      }.freeze
      MAX_BATCH_CHARS = 6_000

      attr_reader :report

      def initialize(
        client:,
        model:,
        source_language: nil,
        target_language:,
        max_batch_chars: MAX_BATCH_CHARS,
        progress: nil
      )
        raise ArgumentError, "translation client is required" unless client
        raise ArgumentError, "translation model is required" if model.to_s.strip.empty?
        raise ArgumentError, "target language is required" if target_language.to_s.strip.empty?

        @client = client
        @model = model
        @source_language = source_language
        @target_language = target_language
        @max_batch_chars = max_batch_chars
        @progress = progress || ->(_message) {}
        @report = {}
      end

      def translate(game_data)
        progress("analyzing game data")
        translated = deep_copy(game_data)
        @original_vocabulary = deep_copy(game_data["vocabulary"] || [])
        @direction_ids = direction_ids(game_data)
        analysis = analyze(translated)
        batches = build_batches(analysis.fetch(:texts))
        progress("found #{analysis.fetch(:texts).length} translatable items in #{batches.length} batch(es)")
        progress("requesting global glossary from AI provider")
        glossary = request_glossary(translated, analysis)

        progress("received global glossary")
        batch_reports = []
        batches.each_with_index do |batch, index|
          progress("translating batch #{index + 1}/#{batches.length} (#{batch.length} item(s))")
          result = request_batch_translation_with_repair(batch, glossary, analysis, index: index)
          merge_batch!(translated, batch, result)
          progress("merged batch #{index + 1}/#{batches.length}")
          batch_reports << { index: index, item_count: batch.length }
        end

        progress("refreshing process vocabulary labels")
        update_process_vocab_labels!(translated)

        @report = {
          "source_language" => source_language,
          "target_language" => target_language,
          "aliases" => "none",
          "glossary" => glossary,
          "batches" => batch_reports,
          "analysis" => reportable_analysis(analysis),
        }

        progress("translation complete")
        translated
      end

      def analyze(game_data)
        texts = translatable_texts(game_data)
        clusters = Hash.new do |hash, key|
          hash[key] = {
            location_id: key == :global ? nil : key,
            process_ids: Set.new,
            message_ids: Set.new,
            system_message_ids: Set.new,
            object_ids: Set.new,
            vocabulary_ids: Set.new,
          }
        end

        process_refs = []
        each_collection_entry(game_data["processes"]) do |process|
          process_id = process["id"] || process[:id]
          Array(process["entries"] || process[:entries]).each_with_index do |entry, entry_index|
            locations = entry_locations(entry)
            cluster_keys = locations.empty? ? [:global] : locations
            cluster_keys.each { |key| clusters[key][:process_ids] << process_id }

            add_entry_vocab_refs(clusters, cluster_keys, entry)

            Array(entry["condacts"] || entry[:condacts]).each_with_index do |condact, condact_index|
              name = condact_name(condact)
              params = condact_params(condact)
              text_kind = TEXT_CONDACTS[name]

              if text_kind && params[0]
                add_text_ref(clusters, cluster_keys, text_kind, params[0])
                process_refs << {
                  process_id: process_id,
                  entry_index: entry_index,
                  condact_index: condact_index,
                  condact: name,
                  target: text_kind,
                  id: params[0],
                  locations: locations,
                }
              end

              add_vocab_condact_refs(clusters, cluster_keys, name, params)
              add_object_refs(clusters, cluster_keys, name, params)
            end
          end
        end

        {
          texts: texts,
          clusters: clusters.transform_values { |cluster| serialize_cluster(cluster) },
          process_text_refs: process_refs,
        }
      end

      private

      attr_reader :client, :model, :source_language, :target_language, :max_batch_chars

      def request_glossary(game_data, analysis)
        body = client.post_chat(
          model: model,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: glossary_prompt(game_data, analysis) },
          ],
        )
        parsed = parse_json_response(body)
        glossary = parsed["glossary"] || parsed
        raise ArgumentError, "translation glossary must be a JSON object" unless glossary.is_a?(Hash)

        glossary
      end

      def request_batch_translation(batch, glossary, analysis, index:)
        body = client.post_chat(
          model: model,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: batch_prompt(batch, glossary, analysis, index) },
          ],
        )
        parsed = parse_json_response(body)
        validate_batch_response!(batch, parsed)
        parsed
      end

      def request_batch_translation_with_repair(batch, glossary, analysis, index:)
        request_batch_translation(batch, glossary, analysis, index: index)
      rescue ArgumentError => e
        progress("batch #{index + 1} failed validation; requesting one repair attempt: #{e.message}")
        begin
          body = client.post_chat(
            model: model,
            messages: [
              { role: "system", content: system_prompt },
              { role: "user", content: batch_prompt(batch, glossary, analysis, index, validation_error: e.message) },
            ],
          )
          parsed = parse_json_response(body)
          validate_batch_response!(batch, parsed)
          parsed
        rescue ArgumentError
          raise e
        end
      end

      def progress(message)
        @progress.call(message)
      end

      def system_prompt
        <<~PROMPT
          You translate extracted PAWS adventure game data.
          Return only valid JSON, with no Markdown fences or explanations.
          Preserve all ids and structural references.
          Never rewrite processes, condact params, connection ids, counters, graphics, or metadata.
          PAWS parser vocabulary entries are command stems: every translated vocabulary word must be uppercase and at most 5 visible characters.
          Visible prose may use full words.
          Preserve PAWS tags like {ink:red}, glyph tags like {glyph:64:a}, newlines, and underscore placeholders.
        PROMPT
      end

      def glossary_prompt(game_data, analysis)
        payload = {
          task: "Build a compact translation glossary for this PAWS adventure.",
          source_language: source_language,
          target_language: target_language,
          rules: [
            "Keep vocabulary command stems at 5 visible characters or fewer.",
            "Keep names, objects, locations, and gameplay terms consistent.",
            "Respect classic commands such as L/LOOK, M/MIRAR, I/INVENTORY/INVENTARIO when relevant.",
            "Keep the glossary compact; do not translate the whole game in this step.",
            "Return only JSON: {\"glossary\":{...}}.",
          ],
          vocabulary: Array(game_data["vocabulary"]).map.with_index do |entry, index|
            {
              index: index,
              id: entry["id"],
              word: entry["word"],
              type_id: entry["type_id"],
              type: entry["type"],
            }
          end,
          objects: collection_with_ids(game_data["objects"]).map { |id, entry| safe_slice(entry, "id", "name", "noun_id", "adjective_id").merge("id" => id) },
          locations: collection_with_ids(game_data["locations"]).map { |id, entry| safe_slice(entry, "id", "description").merge("id" => id) },
          messages_sample: collection_with_ids(game_data["messages"]).first(80).map { |id, entry| { id: id, text: text_value(entry) } },
          system_messages: collection_with_ids(game_data["system_messages"]).map { |id, entry| { id: id, text: text_value(entry) } },
          process_text_refs: analysis.fetch(:process_text_refs),
          clusters: analysis.fetch(:clusters),
        }
        JSON.pretty_generate(payload)
      end

      def batch_prompt(batch, glossary, analysis, index, validation_error: nil)
        payload = {
          task: "Translate this batch. Return only fields for the supplied ids.",
          batch_index: index,
          source_language: source_language,
          target_language: target_language,
          glossary: glossary,
          context_clusters: relevant_clusters(batch, analysis),
          requested_ids: requested_ids_for(batch),
          rules: [
            "Translate every entry listed in items exactly once.",
            "Do not translate or return context_clusters; they are read-only context.",
            "Do not return ids that are absent from requested_ids.",
            "Do not add kind/key/text metadata to returned entries.",
            "Return compact JSON only, with no commentary.",
          ],
          required_shape: {
            locations: [{ id: 1, description: "..." }],
            messages: [{ id: 1, text: "..." }],
            system_messages: [{ id: 1, text: "..." }],
            objects: [{ id: 1, name: "..." }],
            vocabulary: [{ index: 1, word: "STEM" }],
            abbreviations: [{ id: 1, text: "..." }],
          },
          items: batch,
        }
        payload[:previous_validation_error] = validation_error if validation_error
        JSON.pretty_generate(payload)
      end

      def requested_ids_for(batch)
        batch.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |item, memo|
          key = item[:kind].to_s
          memo[key] << (key == "vocabulary" ? item[:index] : item[:id])
        end
      end

      def parse_json_response(body)
        raise ArgumentError, "AI translation returned no response body" if body.nil?

        content = if body.is_a?(String)
            parsed = JSON.parse(body)
            parsed.dig("choices", 0, "message", "content") || body
          else
            body.dig("choices", 0, "message", "content") ||
              body.dig(:choices, 0, :message, :content) ||
              body
          end

        return content if content.is_a?(Hash)

        json = content.to_s.strip
        json = json.sub(/\A```(?:json)?\s*/i, "").sub(/\s*```\z/, "")
        JSON.parse(json)
      rescue JSON::ParserError => e
        raise ArgumentError, "AI translation returned invalid JSON: #{e.message}"
      end

      def translatable_texts(game_data)
        texts = []
        collect_texts(texts, :locations, game_data["locations"], "description")
        collect_texts(texts, :messages, game_data["messages"])
        collect_texts(texts, :system_messages, game_data["system_messages"])
        collect_texts(texts, :objects, game_data["objects"], "name")
        collect_texts(texts, :abbreviations, game_data["abbreviations"], "text")
        Array(game_data["vocabulary"]).each_with_index do |entry, index|
          next if entry["word"].to_s.empty?

          texts << {
            kind: :vocabulary,
            id: entry["id"],
            index: index,
            key: "word",
            text: entry["word"].to_s,
            type_id: entry["type_id"],
          }
        end
        texts
      end

      def collect_texts(texts, kind, values, key = nil)
        collection_with_ids(values).each do |index, entry|
          text = key && entry.is_a?(Hash) ? entry[key] : text_value(entry)
          next if text.to_s.empty?

          texts << { kind: kind, id: entry_id(entry, index), key: key || "text", text: text.to_s }
        end
      end

      def entry_id(entry, index)
        entry.is_a?(Hash) && entry.key?("id") ? entry["id"] : index
      end

      def text_value(entry)
        entry.is_a?(Hash) ? entry["text"] : entry
      end

      def collection_with_ids(values)
        case values
        when Hash
          values.map { |id, entry| [normalize_collection_id(id), entry] }
        else
          Array(values).each_with_index.map { |entry, index| [index, entry] }
        end
      end

      def each_collection_entry(values, &block)
        collection_with_ids(values).each { |_id, entry| block.call(entry) }
      end

      def normalize_collection_id(id)
        id.to_s.match?(/\A\d+\z/) ? id.to_i : id
      end

      def safe_slice(entry, *keys)
        return {} unless entry.is_a?(Hash)

        keys.each_with_object({}) do |key, memo|
          memo[key] = entry[key] if entry.key?(key)
        end
      end

      def build_batches(texts)
        batches = []
        current = []
        size = 0

        texts.each do |item|
          item_size = JSON.generate(item).length
          if current.any? && size + item_size > max_batch_chars
            batches << current
            current = []
            size = 0
          end
          current << item
          size += item_size
        end

        batches << current if current.any?
        batches
      end

      def validate_batch_response!(batch, response)
        raise ArgumentError, "translation batch response must be a JSON object" unless response.is_a?(Hash)

        normalize_batch_response!(response)
        valid_targets = batch.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |item, memo|
          key = item[:kind].to_s
          id_key = key == "vocabulary" ? item[:index] : item[:id]
          memo[key] << id_key
        end
        filter_unrequested_response_entries!(response, valid_targets)
        normalize_translated_markers!(batch, response)

        allowed_keys = %w[locations messages system_messages objects vocabulary abbreviations]
        unknown = response.keys - allowed_keys
        raise ArgumentError, "translation response contains unknown keys: #{unknown.join(", ")}" if unknown.any?

        response.each do |key, values|
          raise ArgumentError, "translation response #{key} must be an array" unless values.is_a?(Array)

          values.each do |entry|
            validate_response_entry!(key, entry, valid_targets)
          end
        end

        validate_complete_batch!(batch, response)
        validate_preserved_markers!(batch, response)
      end

      def normalize_batch_response!(response)
        response.each do |key, values|
          next unless values.is_a?(Array)

          values.each do |entry|
            next unless entry.is_a?(Hash)

            text_key = response_text_key(key)
            entry[text_key] = entry["text"] if !entry.key?(text_key) && entry.key?("text")
            entry.delete("text") unless text_key == "text"
            entry.delete("kind")
            entry.delete("key")
            entry.delete("type")
            entry.delete("type_id")
            normalize_vocabulary_entry!(entry) if key == "vocabulary"
          end
        end
      end

      def normalize_vocabulary_entry!(entry)
        return unless entry.key?("word")

        entry["word"] = visible_text(entry["word"]).upcase[0, 5]
      end

      def filter_unrequested_response_entries!(response, valid_targets)
        ignored = 0
        response.each do |key, values|
          next unless values.is_a?(Array)

          id_key = key == "vocabulary" ? "index" : "id"
          kept = values.select do |entry|
            keep = entry.is_a?(Hash) && valid_targets[key].include?(entry[id_key])
            ignored += 1 unless keep
            keep
          end
          response[key] = kept
        end
        progress("ignored #{ignored} unrequested translated item(s) from provider response") if ignored.positive?
      end

      def normalize_translated_markers!(batch, response)
        entries = response_entries_by_key(response)
        batch.each do |item|
          key = item[:kind].to_s
          id = key == "vocabulary" ? item[:index] : item[:id]
          entry = entries[[key, id]]
          next unless entry

          text_key = response_text_key(key)
          text = TextMarkup.render_glyph_tags(entry[text_key])
          leading_tags = leading_control_tags(item[:text])
          if leading_tags && !text.start_with?(leading_tags)
            text = leading_tags + text.sub(/\A(?:\{(?!glyph:)[^}]+\})+/i, "")
          end
          entry[text_key] = text
        end
      end

      def response_entries_by_key(response)
        response.each_with_object({}) do |(key, values), memo|
          Array(values).each do |entry|
            next unless entry.is_a?(Hash)

            id_key = key == "vocabulary" ? "index" : "id"
            memo[[key, entry[id_key]]] = entry
          end
        end
      end

      def leading_control_tags(text)
        text.to_s[/\A(?:\{(?!glyph:)[^}]+\})+/i]
      end

      def validate_complete_batch!(batch, response)
        expected = batch.map do |item|
          key = item[:kind].to_s
          id = key == "vocabulary" ? item[:index] : item[:id]
          [key, id]
        end.to_set
        actual = response.each_with_object(Set.new) do |(key, values), memo|
          Array(values).each do |entry|
            id_key = key == "vocabulary" ? "index" : "id"
            memo << [key, entry[id_key]]
          end
        end
        missing = expected - actual
        return if missing.empty?

        raise ArgumentError, "translation response missing requested items: #{missing.to_a.map { |key, id| "#{key}:#{id}" }.join(", ")}"
      end

      def validate_response_entry!(key, entry, valid_targets)
        raise ArgumentError, "translation response #{key} entry must be an object" unless entry.is_a?(Hash)

        id_key = key == "vocabulary" ? "index" : "id"
        allowed = [id_key, response_text_key(key)]
        unknown = entry.keys - allowed
        raise ArgumentError, "translation response #{key} entry has unknown keys: #{unknown.join(", ")}" if unknown.any?

        id = entry[id_key]
        raise ArgumentError, "translation response #{key} id #{id.inspect} was not requested" unless valid_targets[key].include?(id)

        value = entry[response_text_key(key)]
        raise ArgumentError, "translation response #{key} #{id} text must be a string" unless value.is_a?(String)

        if key == "vocabulary"
          stem = visible_text(value)
          raise ArgumentError, "translated vocabulary #{id} is longer than 5 visible characters: #{value}" if stem.length > 5
          raise ArgumentError, "translated vocabulary #{id} must be uppercase: #{value}" unless value == value.upcase
        end
      end

      def validate_preserved_markers!(batch, response)
        response_lookup = response.each_with_object({}) do |(key, values), memo|
          values.each do |entry|
            id_key = key == "vocabulary" ? "index" : "id"
            memo[[key, entry[id_key]]] = entry[response_text_key(key)]
          end
        end

        batch.each do |item|
          key = item[:kind].to_s
          id = key == "vocabulary" ? item[:index] : item[:id]
          translated = response_lookup[[key, id]]
          next unless translated

          source = item[:text].to_s
          assert_no_new_tags!(tag_tokens(source), tag_tokens(translated), key, id)
          assert_no_new_glyphs!(glyph_tokens(source), glyph_tokens(translated), key, id)
          if source.count("_") != translated.count("_")
            raise ArgumentError, "translation changed underscore placeholders for #{key} #{id}"
          end
        end
      end

      def assert_marker_multiset!(label, source_tokens, translated_tokens, key, id)
        return if source_tokens.sort == translated_tokens.sort

        raise ArgumentError, "translation changed #{label} for #{key} #{id}"
      end

      def assert_no_new_tags!(source_tokens, translated_tokens, key, id)
        extra = translated_tokens.dup
        source_tokens.each do |token|
          index = extra.index(token)
          extra.delete_at(index) if index
        end
        return if extra.empty?

        raise ArgumentError, "translation introduced unknown tags for #{key} #{id}"
      end

      def assert_no_new_glyphs!(source_tokens, translated_tokens, key, id)
        extra = translated_tokens.dup
        source_tokens.each do |token|
          index = extra.index(token)
          extra.delete_at(index) if index
        end
        return if extra.empty?

        raise ArgumentError, "translation introduced unknown glyphs for #{key} #{id}"
      end

      def tag_tokens(text)
        text.to_s.scan(/\{(?!glyph:)[^}]+\}/i)
      end

      def glyph_tokens(text)
        text.to_s.scan(/\{glyph:\d+:[^}]*\}/i)
      end

      def response_text_key(key)
        case key
        when "locations" then "description"
        when "objects" then "name"
        when "vocabulary" then "word"
        else "text"
        end
      end

      def merge_batch!(game_data, _batch, response)
        merge_collection!(game_data, response, "locations", "description")
        merge_collection!(game_data, response, "messages", "text")
        merge_collection!(game_data, response, "system_messages", "text")
        merge_collection!(game_data, response, "objects", "name")
        merge_collection!(game_data, response, "abbreviations", "text")
        merge_vocabulary!(game_data, response["vocabulary"])
      end

      def merge_collection!(game_data, response, key, text_key)
        Array(response[key]).each do |translation|
          id = translation.fetch("id")
          value = translation.fetch(text_key)
          collection = game_data[key] || []
          current = collection_item(collection, id)
          if current.is_a?(Hash)
            current[text_key] = value
          elsif collection.is_a?(Hash)
            collection[id.to_s] = value
          else
            collection[id] = value
          end
        end
      end

      def collection_item(collection, id)
        if collection.is_a?(Hash)
          collection[id.to_s] || collection[id]
        else
          collection[id]
        end
      end

      def merge_vocabulary!(game_data, entries)
        Array(entries).each do |translation|
          index = translation.fetch("index")
          entry = game_data.dig("vocabulary", index)
          next unless entry

          proposed = visible_text(translation.fetch("word")).upcase[0, 5]
          entry["word"] = safe_vocabulary_word(game_data["vocabulary"], index, proposed)
        end
      end

      def safe_vocabulary_word(vocabulary, index, proposed)
        original = @original_vocabulary[index] || vocabulary[index]
        return original["word"] if direction_expansion?(original, proposed)

        type_id = original["type_id"]
        id = original["id"]
        return original["word"] if original_vocabulary_collision?(type_id, id, proposed)
        return original["word"] if current_vocabulary_collision?(vocabulary, index, type_id, id, proposed)

        proposed
      end

      def direction_expansion?(entry, proposed)
        entry &&
          entry["type_id"] == 2 &&
          @direction_ids.include?(entry["id"]) &&
          entry["word"].to_s.length <= 2 &&
          proposed.length > 2
      end

      def original_vocabulary_collision?(type_id, id, proposed)
        @original_vocabulary.any? do |entry|
          entry["type_id"] == type_id &&
            entry["id"] != id &&
            entry["word"].to_s.upcase == proposed
        end
      end

      def current_vocabulary_collision?(vocabulary, index, type_id, id, proposed)
        vocabulary.each_with_index.any? do |entry, entry_index|
          next false if entry_index == index

          entry["type_id"] == type_id &&
            entry["id"] != id &&
            entry["word"].to_s.upcase == proposed
        end
      end

      def direction_ids(game_data)
        Array(game_data["connections"]).each_with_object(Set.new) do |row, ids|
          Array(row[1]).each { |direction, _destination| ids << direction }
        end
      end

      def update_process_vocab_labels!(game_data)
        vocab = game_data["vocabulary"] || []
        each_collection_entry(game_data["processes"]) do |process|
          Array(process["entries"]).each do |entry|
            entry["verb_name"] = vocab_word(vocab, entry["verb"], 0)
            entry["noun_name"] = vocab_word(vocab, entry["noun"], 2)
          end
        end
      end

      def vocab_word(vocabulary, id, type_id)
        return "*" if id == 0 || id == 1
        return "_" if id == 255

        entry = vocabulary.find { |item| item["id"] == id && item["type_id"] == type_id }
        entry ? entry["word"] : "ID#{id}"
      end

      def visible_text(text)
        TextMarkup.strip_tags(text.to_s)
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def entry_locations(entry)
        Array(entry["condacts"] || entry[:condacts]).filter_map do |condact|
          name = condact_name(condact)
          next unless LOCATION_CONDACTS.include?(name)

          condact_params(condact)[0]
        end.uniq
      end

      def add_entry_vocab_refs(clusters, cluster_keys, entry)
        [[entry["verb"], 0], [entry["noun"], 2]].each do |id, type_id|
          next if [nil, 0, 1, 255].include?(id)

          cluster_keys.each { |key| clusters[key][:vocabulary_ids] << "#{type_id}:#{id}" }
        end
      end

      def add_vocab_condact_refs(clusters, cluster_keys, name, params)
        type_id = VOCAB_CONDACTS[name]
        return unless type_id && params[0]

        cluster_keys.each { |key| clusters[key][:vocabulary_ids] << "#{type_id}:#{params[0]}" }
      end

      def add_object_refs(clusters, cluster_keys, name, params)
        return unless OBJECT_CONDACTS.include?(name) && params[0]

        cluster_keys.each { |key| clusters[key][:object_ids] << params[0] }
      end

      def add_text_ref(clusters, cluster_keys, kind, id)
        cluster_keys.each do |key|
          case kind
          when :messages then clusters[key][:message_ids] << id
          when :system_messages then clusters[key][:system_message_ids] << id
          when :locations then clusters[key][:location_id] ||= id
          end
        end
      end

      def serialize_cluster(cluster)
        cluster.transform_values do |value|
          value.is_a?(Set) ? value.to_a.sort_by(&:to_s) : value
        end
      end

      def relevant_clusters(batch, analysis)
        wanted_locations = batch.select { |item| item[:kind] == :locations }.map { |item| item[:id] }
        clusters = analysis.fetch(:clusters)
        return clusters if wanted_locations.empty?

        clusters.select { |key, _value| key == :global || wanted_locations.include?(key) }
      end

      def reportable_analysis(analysis)
        {
          "text_count" => analysis.fetch(:texts).length,
          "cluster_count" => analysis.fetch(:clusters).length,
          "process_text_ref_count" => analysis.fetch(:process_text_refs).length,
        }
      end

      def condact_name(condact)
        (condact["name"] || condact[:name]).to_s.upcase
      end

      def condact_params(condact)
        condact["params"] || condact[:params] || []
      end
    end
  end
end
