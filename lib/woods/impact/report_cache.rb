# frozen_string_literal: true

module Woods
  module Impact
    # A bounded, thread-safe, per-process store of computed range comparisons,
    # keyed by the exact payloads a range resolved to (generation, payload
    # directory and manifest digest on each side) and its parameters. Retained
    # payloads never change once published, so an entry never goes stale; a
    # new publish changes what `now` or a SHA resolves to, and so the key.
    #
    # The most recently used entries are kept. A failure is never kept. Two
    # threads that miss on one key at once may both compute it.
    class ReportCache
      # @param size [Integer] entries kept
      def initialize(size: 4)
        raise ArgumentError, 'ReportCache size must be a positive Integer' unless size.is_a?(Integer) && size.positive?

        @size = size
        @entries = {}
        @mutex = Mutex.new
      end

      # @param key [Array] frozen-compatible identity of one comparison
      # @yieldreturn [Object] the comparison, computed on a miss
      # @return [Object]
      def fetch(key)
        hit = @mutex.synchronize { @entries[key] = @entries.delete(key) if @entries.key?(key) }
        return hit unless hit.nil?

        value = yield
        @mutex.synchronize do
          @entries.delete(key)
          @entries.shift while @entries.size >= @size
          @entries[key] = value
        end
        value
      end

      # @return [Integer] entries held
      def size
        @mutex.synchronize { @entries.size }
      end

      # Drop every entry.
      # @return [void]
      def clear
        @mutex.synchronize { @entries.clear }
      end
    end
  end
end
