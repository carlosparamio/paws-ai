# frozen_string_literal: true

module PAWS
  # Builds OpenAI-compatible chat payloads for the AI-assisted parser.
  # The builder is a Template Method-style collaborator: AIParser owns the parse
  # use case, while this class owns vocabulary formatting, prompt template
  # loading, and provider-neutral message construction.
  class AIPromptBuilder
    COMMUNICATION_VERBS = %w[DI DIGO TELL SAY PREGU ASK].freeze
    TELL_VERBS = %w[DI DIGO TELL SAY].freeze
    ASK_VERBS = %w[PREGU ASK].freeze

    def initialize(template_loader: nil, warn: nil)
      @template_loader = template_loader
      @warn = warn || ->(message) { Kernel.warn(message) }
    end

    def request_payload(input, context, model:)
      prompt = construct_prompt(input, context).to_s.strip
      if prompt.empty?
        warn.call("AI Parser Prompt Error: user prompt is empty")
        return nil
      end

      {
        model: model,
        messages: request_messages(load_template("system"), prompt),
      # Avoid response_format: { type: 'json_object' } for broader provider compatibility.
      }
    end

    private

    attr_reader :template_loader, :warn

    def request_messages(system_prompt, user_prompt)
      [
        message(:system, system_prompt),
        message(:user, user_prompt),
      ].compact
    end

    def message(role, content)
      content = content.to_s.strip
      return nil if content.empty?

      { role: role.to_s, content: content }
    end

    def load_template(name, variables = {})
      return template_loader.call(name, variables) if template_loader

      path = File.expand_path("../../prompts/ai_parser/#{name}.md", __dir__)
      return "" unless File.exist?(path)

      template = File.read(path)
      variables.each do |key, value|
        template = template.gsub("{{#{key}}}", value.to_s)
      end
      template
    end

    def construct_prompt(input, context)
      di_id, preg_id = communication_ids(context)

      template_name = context[:is_nested] ? "nested_mode" : "normal_mode"
      load_template(template_name, {
        game_title: context[:game_title],
        location: context[:location],
        inventory: context[:inventory].join(", "),
        visible_objects: list_lines(context[:visible_objects]),
        history: context[:history].join("\n"),
        vocab_list: vocabulary_list(context[:vocabulary]),
        intent_index: intent_index_list(context[:intent_index]),
        input: input,
        di_id: di_id,
        preg_id: preg_id,
        actions_list: actions_list(context[:response_table]),
        parse_actions_list: parse_actions_list(context[:parse_response_table]),
      })
    end

    def communication_ids(context)
      comm_verbs = context[:vocabulary].select do |entry|
        entry[:type] == 0 && COMMUNICATION_VERBS.include?(entry[:word].upcase)
      end

      di_id = (comm_verbs.find { |entry| TELL_VERBS.include?(entry[:word].upcase) } || {})[:id] || 32
      preg_id = (comm_verbs.find { |entry| ASK_VERBS.include?(entry[:word].upcase) } || {})[:id] || 33

      [di_id, preg_id]
    end

    def vocabulary_list(vocabulary)
      vocabulary.map do |entry|
        type_name = vocabulary_type_name(entry[:type])
        "#{entry[:id].to_s.rjust(3)}: #{entry[:word].ljust(15)} [#{type_name}]"
      end.join("\n")
    end

    def vocabulary_type_name(type_id)
      case type_id
      when 0 then "verb"
      when 1 then "adverb"
      when 2 then "noun"
      when 3 then "adjective"
      when 4 then "preposition"
      else "other"
      end
    end

    def actions_list(response_table)
      Array(response_table).map do |entry|
        checks = format_checks(entry[:checks])
        "- #{format_pair(entry)} #{checks.empty? ? "" : "(Also checks: #{checks})"}"
      end.join("\n")
    end

    def parse_actions_list(parse_response_table)
      lines = []
      Array(parse_response_table).each do |entry|
        lines << "- #{format_pair(entry)} can re-parse quoted speech through:"
        Array(entry[:processes]).each do |process|
          Array(process[:entries]).each do |parse_entry|
            checks = format_checks(parse_entry[:checks])
            suffix = checks.empty? ? "" : " (Also checks: #{checks})"
            lines << "  - #{format_pair(parse_entry)}#{suffix}"
          end
        end
      end
      lines.join("\n")
    end

    def format_pair(entry)
      "#{format_word(entry[:verb], entry[:verb_aliases])} #{format_word(entry[:noun], entry[:noun_aliases])}"
    end

    def format_word(primary, aliases)
      values = Array(aliases).compact.map(&:to_s).reject(&:empty?)
      values = [primary.to_s] if values.empty?
      values.uniq.join("/")
    end

    def format_checks(checks)
      Array(checks).map do |check|
        word = format_word(check[:word], check[:aliases])
        "#{word} (#{check[:type]})"
      end.join(", ")
    end

    # Renders the full intent index compiled from every process table as a
    # JSON array that mirrors the output schema the model is expected to emit:
    # every entry is an object with the SAME field names (verb, noun1,
    # adject1, adject2, noun2, adverb, prep), so the model can pattern-match
    # user input to one of these templates and translate words back to IDs
    # via the Vocabulary List above. Words are used (instead of IDs) so the
    # model can match free-form input directly; aliases are joined with "/"
    # exactly as in the Vocabulary List.
    #
    # Check slots that surface multiple distinct words across the blocks
    # sharing a verb+noun pair (e.g. several NOUN2 values, several prepositions)
    # are rendered as arrays so the model sees every option the game accepts.
    def intent_index_list(intent_index)
      entries = Array(intent_index).map { |entry| intent_index_entry(entry) }
      JSON.pretty_generate(entries)
    end

    def intent_index_entry(entry)
      slot = {
        "verb"    => intent_slot_word(entry[:verb], entry[:verb_aliases]),
        "noun1"   => intent_slot_word(entry[:noun], entry[:noun_aliases]),
        "adject1" => [],
        "adject2" => [],
        "noun2"   => [],
        "adverb"  => [],
        "prep"    => [],
      }

      Array(entry[:checks]).each do |check|
        word = format_word(check[:word], check[:aliases])
        next if word.empty?

        case check[:type]
        when "adjective1"  then (slot["adject1"] << word)
        when "adjective2"  then (slot["adject2"] << word)
        when "noun"        then (slot["noun2"]   << word)
        when "adverb"      then (slot["adverb"]  << word)
        when "preposition" then (slot["prep"]    << word)
        end
      end

      slot.transform_values do |value|
        value.is_a?(Array) ? value.uniq : value
      end
    end

    def intent_slot_word(primary, aliases)
      formatted = format_word(primary, aliases)
      formatted.empty? ? nil : formatted
    end

    def list_lines(values)
      Array(values).map { |value| "- #{value}" }.join("\n")
    end
  end
end
