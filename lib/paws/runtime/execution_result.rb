# frozen_string_literal: true

module PAWS
  # Value object for condact execution outcomes.
  # Runtime code uses this object instead of inspecting symbols and arrays by
  # hand. `.from` remains intentionally small and defensive so old direct helper
  # calls can still be normalized at the boundary while handlers migrate.
  class ExecutionResult
    STATUSES = %i[ok failed unsupported abort executing done continue_scan].freeze

    attr_reader :status, :details

    def self.ok(details = nil)
      new(:ok, details)
    end

    def self.failed(details = nil)
      new(:failed, details)
    end

    def self.unsupported(details = nil)
      new(:unsupported, details)
    end

    def self.abort(details = nil)
      new(:abort, details)
    end

    def self.continue_scan(details = nil)
      new(:continue_scan, details)
    end

    def self.from(value)
      return value if value.is_a?(self)

      if value.is_a?(Array)
        new(value[0], value[1])
      else
        new(value, nil)
      end
    end

    def initialize(status, details = nil)
      @status = status.to_sym
      @details = details
      raise ArgumentError, "Unknown execution status: #{status}" unless STATUSES.include?(@status)
    end

    def ok?
      status == :ok
    end

    def failed?
      status == :failed
    end

    def unsupported?
      status == :unsupported
    end

    def abort?
      status == :abort
    end

    def done?
      status == :done
    end

    def continue_scan?
      status == :continue_scan
    end

    def to_a
      [status, details]
    end

    def ==(other)
      case other
      when ExecutionResult then status == other.status && details == other.details
      else status == other
      end
    end
  end
end
