# frozen_string_literal: true

module PAWS
  # Loads a local .env file without making dotenv a hard runtime dependency.
  module EnvLoader
    module_function

    def load(path = ".env", env: ENV)
      return false unless File.exist?(path)

      File.readlines(path, chomp: true).each do |line|
        key, value = parse_line(line)
        next unless key
        next if env.key?(key)

        env[key] = value
      end
      true
    end

    def parse_line(line)
      text = line.to_s.strip
      return nil if text.empty? || text.start_with?("#")

      text = text.delete_prefix("export ").strip
      key, separator, value = text.partition("=")
      return nil if separator.empty?

      key = key.strip
      return nil unless key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

      [key, unquote(value.strip)]
    end

    def unquote(value)
      if (value.start_with?('"') && value.end_with?('"')) ||
          (value.start_with?("'") && value.end_with?("'"))
        value[1..-2]
      else
        value
      end
    end
  end
end
