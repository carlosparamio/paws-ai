# frozen_string_literal: true

module PAWS
  # Parses raw debugger REPL input into a small command object.
  # Debugger keeps dispatching commands, but this class owns normalization,
  # tokenization, and the empty-command convention used by the REPL.
  class DebugCommandParser
    Command = Struct.new(:raw, :normalized, :parts, :base, :arg, keyword_init: true) do
      def empty?
        normalized.empty?
      end
    end

    def parse(input)
      raw = input.to_s.strip
      normalized = raw.downcase
      parts = normalized.split(/\s+/)

      Command.new(
        raw: raw,
        normalized: normalized,
        parts: parts,
        base: parts[0],
        arg: parts[1],
      )
    end
  end
end
