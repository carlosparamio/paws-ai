# frozen_string_literal: true

module PAWS
  module Debug
    # Interface adapter used by the remote debugger to run the same command
    # handlers as the inline REPL while capturing their textual output.
    class CaptureInterface
      def initialize(delegate)
        @delegate = delegate
        @buffer = +""
      end

      def output_text(text = "", newline: true)
        @buffer << text.to_s
        @buffer << "\n" if newline
      end

      def output_debug(message, _level = 1)
        output_text(message.to_s)
      end

      def get_input(timeout: nil, prompt: "")
        nil
      end

      def fmt_p(process_id)
        format("P%03d", process_id)
      end

      def fmt_b(block_id)
        format("B%03d", block_id)
      end

      def fmt_c(condact_id)
        format("C%03d", condact_id)
      end

      def flush
        output = @buffer.dup
        @buffer.clear
        output
      end

      def install_autoplay_commands(commands)
        @delegate.install_autoplay_commands(commands)
      end

      def method_missing(name, *args, &block)
        return @delegate.public_send(name, *args, &block) if @delegate.respond_to?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @delegate.respond_to?(name, include_private) || super
      end
    end
  end
end
