# frozen_string_literal: true

module Woods
  module Diagrams
    # Results per generation (woods#826): the key starts with the reader's
    # generation identity (number, publish token, payload directory), so a new
    # publish never serves an old diagram, and a bounded number of entries is
    # kept, oldest dropped first. Thread-safe for woods-mcp-http's request
    # threads; a builder runs outside the lock.
    module Cache
      # Entries kept at most.
      LIMIT = 256

      @entries = {}
      @mutex = Mutex.new

      module_function

      # @param key [Array] the generation identity first, then the request
      # @yieldreturn [Result]
      # @return [Result] the cached or freshly built result
      def fetch(key)
        cached = @mutex.synchronize { @entries[key] }
        return cached if cached

        result = yield.freeze
        @mutex.synchronize do
          @entries.delete(key)
          @entries[key] = result
          @entries.shift while @entries.size > LIMIT
        end
        result
      end

      # Drop every entry (specs, and a host that wants the memory back).
      #
      # @return [void]
      def clear
        @mutex.synchronize { @entries.clear }
      end

      # @return [Integer] entries held
      def size
        @mutex.synchronize { @entries.size }
      end
    end
  end
end
