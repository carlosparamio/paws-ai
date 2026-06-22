# frozen_string_literal: true

require "json"

module PAWS
  # Filesystem adapter for PAWS save games.
  # CLIInterface owns the user prompts, while this store owns filename normalization,
  # JSON serialization, and file IO for SAVE/LOAD condacts.
  class SaveGameStore
    def save(filename, state)
      File.write(normalize_filename(filename), state.to_json)
    end

    def load(filename)
      JSON.parse(File.read(normalize_filename(filename)), symbolize_names: true)
    end

    def exist?(filename)
      File.exist?(normalize_filename(filename))
    end

    private

    def normalize_filename(filename)
      filename.end_with?(".sav") ? filename : "#{filename}.sav"
    end
  end
end
