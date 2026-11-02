# frozen_string_literal: true

require 'digest'
require 'prism'

module Woods
  # One Prism parse per distinct source for the length of an extraction run.
  #
  # A unit's source is read by several analyses that each parsed it again:
  # lexical nesting, the method table, callback sites, test examples, the
  # PORO walker, and so on. On a 10,000-unit app that was ~10,700 parses for
  # ~1,900 distinct sources. The cache is keyed by content digest,
  # so two units that embed the same concern share one parse and a file
  # edited between two incremental runs is parsed again.
  #
  # The cache is live only inside {.with}; outside a run {.parse} is a plain
  # `Prism.parse`, so MCP servers and one-off readers never hold trees. It
  # evicts least-recently-used entries past a budget of cached source bytes
  # and is safe to share between the concurrent-extraction threads.
  #
  # The budget is deliberately small. Nearly all repeats are a unit's own
  # source and the concerns it embeds, read again by the next analysis of
  # the same unit, so a window of a few hundred files catches them; holding
  # every tree for the run instead (16 MB of source on the 10k-unit testbed)
  # doubled GC marking time and gave the saving straight back. Set
  # `config.parse_cache_source_bytes` to tune it, 0 to disable.
  #
  # Parse results are shared objects: callers read them and never mutate the
  # tree, which is how every existing analysis already treats a `Prism.parse`.
  module ParseCache
    DEFAULT_BUDGET = 1024 * 1024

    # An LRU of parse results bounded by cached source bytes.
    class Store
      attr_reader :hits, :parses

      def initialize(budget:)
        @budget = budget
        @entries = {}
        @bytes = 0
        @hits = 0
        @parses = 0
        @lock = Mutex.new
      end

      # @param source [String]
      # @return [Prism::ParseResult]
      def parse(source)
        derive(:prism, source) { Prism.parse(source) }
      end

      # Memoize any derivation of +source+ under +family+ (the Prism result,
      # the normalized {Woods::Ast::Node} tree, …). The block runs outside
      # the lock, so two threads may both compute a miss; the second result
      # simply replaces the first.
      #
      # @param family [Symbol]
      # @param source [String]
      # @return [Object] the block's value
      def derive(family, source)
        key = [family, Digest::SHA256.digest(source)]
        @lock.synchronize do
          if (entry = @entries.delete(key))
            @hits += 1
            @entries[key] = entry
            return entry.last
          end
        end
        result = yield
        @lock.synchronize do
          @parses += 1
          store(key, source.bytesize, result)
        end
        result
      end

      private

      def store(key, size, result)
        return result if size > @budget

        @bytes -= @entries[key].first if @entries.key?(key)
        @entries.delete(key)
        @entries[key] = [size, result]
        @bytes += size
        while @bytes > @budget && @entries.size > 1
          _old, (old_size, _r) = @entries.shift
          @bytes -= old_size
        end
        result
      end
    end

    class << self
      # Parse through the active run's cache, or directly when no run is active.
      #
      # @param source [String] Ruby source
      # @return [Prism::ParseResult]
      def parse(source)
        store = @store
        store ? store.parse(source) : Prism.parse(source)
      end

      # Memoize a derivation of +source+ for the run, or compute it when no
      # run is active.
      #
      # @param family [Symbol] what the block derives, e.g. +:ast+
      # @param source [String]
      # @return [Object] the block's value
      def derive(family, source, &block)
        store = @store
        store ? store.derive(family, source, &block) : yield
      end

      # Run the block with a cache live. Nested calls share the outer cache.
      #
      # @param budget [Integer] cached source bytes; 0 disables caching
      # @yieldreturn the block's value
      def with(budget: DEFAULT_BUDGET)
        return yield if @store || budget.to_i <= 0

        @store = Store.new(budget: budget)
        begin
          yield
        ensure
          @store = nil
        end
      end

      # @return [Store, nil] the active store, for run statistics
      def active
        @store
      end
    end
  end
end
