# frozen_string_literal: true

require "thread"

module PAWS
  module Debug
    class RemoteRegistry
      def initialize
        @mutex = Mutex.new
        @controllers = {}
      end

      def register(controller)
        @mutex.synchronize { @controllers[controller.id] = controller }
        controller
      end

      def unregister(id)
        @mutex.synchronize { @controllers.delete(id) }
      end

      def find(id)
        @mutex.synchronize { @controllers[id] }
      end

      def current
        @mutex.synchronize { @controllers.values.find(&:paused?) || @controllers.values.first }
      end

      def sessions
        @mutex.synchronize { @controllers.values.map(&:summary) }
      end
    end
  end
end
