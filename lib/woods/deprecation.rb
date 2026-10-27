# frozen_string_literal: true

require 'set'

module Woods
  # One-line deprecation notices, printed at most once per process per key.
  module Deprecation
    @warned = Set.new
    @mutex = Mutex.new

    class << self
      # @param key [Symbol, String] identifies the deprecated surface
      # @param message [String] one line pointing at the replacement
      # @return [void]
      def warn_once(key, message)
        first = @mutex.synchronize { @warned.add?(key.to_s) }
        Kernel.warn("[woods] DEPRECATED: #{message}") if first
      end

      # Forget every key already warned about. For specs.
      #
      # @return [void]
      def reset!
        @mutex.synchronize { @warned.clear }
      end
    end
  end
end
