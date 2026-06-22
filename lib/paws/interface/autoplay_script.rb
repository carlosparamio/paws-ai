# frozen_string_literal: true

module PAWS
  # Loads command-history files for autoplay, with optional 1-based inclusive ranges.
  class AutoplayScript
    RANGE_PATTERN = /\A(?:all|[1-9]\d*-[1-9]\d*)\z/i
    COMMENT_PATTERN = /\A\s*[#;]/

    class Error < StandardError; end

    def self.load(path, range: nil)
      new(path, range: range).commands
    end

    def self.parse_cli_spec(spec, range: nil)
      return [nil, range] if spec.nil?
      return [spec, range] if range

      path, suffix = spec.rpartition(":").values_at(0, 2)
      return [spec, nil] if path.empty? || suffix.empty?
      return [spec, nil] unless suffix.match?(RANGE_PATTERN)
      return [spec, nil] if File.exist?(spec)

      [path, suffix]
    end

    def initialize(path, range: nil)
      @path = path
      @range = normalize_range(range)
    end

    def commands
      lines = File.readlines(@path, chomp: true).filter_map { |line| command_line(line) }
      return lines if @range == :all

      first, last = @range
      lines[(first - 1)..(last - 1)] || []
    rescue Errno::ENOENT
      raise Error, "Autoplay file not found: #{@path}"
    end

    private

    def normalize_range(range)
      return :all if range.nil? || range.to_s.strip.empty?

      value = range.to_s.strip
      return :all if value.casecmp("all").zero?

      match = value.match(/\A([1-9]\d*)-([1-9]\d*)\z/)
      raise Error, "Invalid autoplay range '#{range}' (expected all or n-m)" unless match

      first = match[1].to_i
      last = match[2].to_i
      raise Error, "Invalid autoplay range '#{range}' (first line must be <= last line)" if first > last

      [first, last]
    end

    def command_line(line)
      value = line.to_s.strip
      return nil if value.empty? || value.match?(COMMENT_PATTERN)

      value
    end
  end
end
