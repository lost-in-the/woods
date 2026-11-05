# frozen_string_literal: true

require 'objspace'

module Woods
  module Retrieval
    # Tokenized lexical fields kept between index builds in one process, so a
    # new generation re-tokenizes only the units whose indexed text changed.
    #
    # An entry is keyed by a digest of the text the tokenizer reads (see
    # {LexicalIndex.field_digest}) and belongs to one lexical configuration
    # ({LexicalIndex.configuration_key}); a build under another configuration
    # starts from nothing. An entry carries +[digest, fields, terms, lengths]+
    # only: frozen Strings, Integers, Hashes and Arrays. Units, keys, paths,
    # identities and corpus statistics always come from the generation being
    # built, and no entry refers to a Class or Module.
    #
    # Bounded twice: an entry is dropped once {max_builds} later committed
    # builds have not used it, and the oldest entries go first while the
    # estimated size is over {max_bytes}. A build that raises commits nothing.
    # Nothing is written to disk.
    class LexicalTokenCache
      # Two builds: the live generation and the one before it, so a reader
      # switching between two pinned generations re-tokenizes neither.
      DEFAULT_MAX_BUILDS = 2
      DEFAULT_MAX_BYTES = 256 * 1024 * 1024
      ENTRY_FLOOR_BYTES = 40
      private_constant :ENTRY_FLOOR_BYTES

      # One build's view: lookups read the table as it stood when the build
      # began, and the build's new and reused entries are committed together.
      class Build
        attr_reader :configuration, :entries, :hits, :misses

        def initialize(configuration, table)
          @configuration = configuration
          @table = table
          @entries = {}
          @hits = 0
          @misses = 0
        end

        # @param digest [String] {LexicalIndex.field_digest} of a unit
        # @yieldreturn [Array(Hash, Array, Hash)] fields, terms and lengths
        # @return [Array] the frozen entry +[digest, fields, terms, lengths]+
        def fetch(digest)
          entry = @entries[digest] || @table[digest]
          if entry
            @hits += 1
          else
            @misses += 1
            entry = [digest.dup.freeze, *yield].freeze
          end
          @entries[digest] = entry
        end
      end

      # The cache every published lexical snapshot in this process shares.
      #
      # @return [LexicalTokenCache]
      class << self
        attr_reader :shared
      end

      attr_reader :max_bytes, :max_builds

      def initialize(max_bytes: DEFAULT_MAX_BYTES, max_builds: DEFAULT_MAX_BUILDS)
        raise ArgumentError, 'max_builds must be positive' unless max_builds.is_a?(Integer) && max_builds.positive?
        unless max_bytes.is_a?(Integer) && !max_bytes.negative?
          raise ArgumentError, 'max_bytes must be a non-negative Integer'
        end

        @max_bytes = max_bytes
        @max_builds = max_builds
        @mutex = Mutex.new
        clear!
      end

      # @param configuration [String] {LexicalIndex.configuration_key}
      # @return [Build]
      def begin_build(configuration)
        @mutex.synchronize do
          Build.new(configuration, configuration == @configuration ? @table : {}.freeze)
        end
      end

      # Keep +build+'s entries, then apply both bounds.
      #
      # @param build [Build]
      # @return [void]
      def commit(build)
        @mutex.synchronize do
          reset(build.configuration) unless build.configuration == @configuration
          @builds += 1
          @last_build = { hits: build.hits, misses: build.misses }
          table = @table.dup
          build.entries.each do |digest, entry|
            table[digest] = entry
            @bytes[digest] ||= entry_bytes(entry)
            @used.delete(digest)
            @used[digest] = @builds
          end
          @table = table
          evict
          @table.freeze
        end
      end

      # @return [Hash] entry count, estimated bytes, committed builds and the
      #   last committed build's hits and misses
      def stats
        @mutex.synchronize do
          { entries: @table.size, bytes: @bytes.values.sum, builds: @builds,
            last_build: @last_build }
        end
      end

      # Every object an entry holds, for the spec that proves none is a Class
      # or Module.
      #
      # @return [Array]
      def entries
        @mutex.synchronize { @table.values }
      end

      def clear!
        @mutex.synchronize { reset(nil) }
      end

      private

      def reset(configuration)
        @configuration = configuration
        @table = {}.freeze
        @bytes = {}
        @used = {}
        @builds ||= 0
        @last_build = nil
      end

      # @used is ordered from least to most recently used, so the stale and
      # the over-budget evictions both drop from its front.
      def evict
        total = @bytes.values.sum
        dropped = []
        @used.each do |digest, build|
          break unless build <= @builds - @max_builds || total > @max_bytes

          total -= @bytes.fetch(digest)
          dropped << digest
        end
        dropped.each do |digest|
          @bytes.delete(digest)
          @table.delete(digest)
          @used.delete(digest)
        end
      end

      # Charge every retained object once within an entry. Strings can share
      # backing storage (including interned tokens), so charge their full bytes
      # conservatively even when another entry or live index also holds them.
      def entry_bytes(entry)
        seen = {}.compare_by_identity
        pending = [entry]
        total = 0
        until pending.empty?
          object = pending.pop
          next if seen.key?(object)

          seen[object] = true
          size = [ObjectSpace.memsize_of(object), ENTRY_FLOOR_BYTES].max
          size = [size, ENTRY_FLOOR_BYTES + object.bytesize].max if object.is_a?(String)
          total += size
          pending.concat(object) if object.is_a?(Array)
          pending.concat(object.to_a.flatten(1)) if object.is_a?(Hash)
        end
        total
      end

      # Created at load, so concurrent first callers cannot make two.
      @shared = new
    end
  end
end
