# frozen_string_literal: true

require 'digest'
require 'json'

module CodebaseIndex
  module Cache
    # Default TTLs (in seconds) for each cache domain.
    #
    # Embedding vectors are stable (same text → same vector) so they get 24h.
    # Metadata and structural context refresh on re-extraction (1h).
    # Search results and formatted context are session-scoped (15min).
    DEFAULT_TTLS = {
      embeddings: 86_400,
      metadata: 3_600,
      structural: 3_600,
      search: 900,
      context: 900
    }.freeze

    # Build a namespaced cache key from a domain and raw parts.
    #
    # @param domain [Symbol] Cache domain (:embeddings, :metadata, etc.)
    # @param parts [Array<String>] Key components (will be SHA256-hashed if long)
    # @return [String] Namespaced key
    def self.cache_key(domain, *parts)
      raw = parts.join(':')
      suffix = raw.length > 64 ? Digest::SHA256.hexdigest(raw) : raw
      "codebase_index:cache:#{domain}:#{suffix}"
    end

    # Abstract cache store interface.
    #
    # All cache backends must implement these methods. The interface is modeled
    # after ActiveSupport::Cache::Store for familiarity but kept minimal.
    #
    # @abstract Subclass and override all public methods.
    class CacheStore
      # Read a value from the cache.
      #
      # @param key [String] Cache key
      # @return [Object, nil] Cached value or nil if missing/expired
      def read(key)
        raise NotImplementedError
      end

      # Write a value to the cache.
      #
      # @param key [String] Cache key
      # @param value [Object] Value to cache (must be JSON-serializable)
      # @param ttl [Integer, nil] Time-to-live in seconds (nil = use domain default)
      # @return [void]
      def write(key, value, ttl: nil)
        raise NotImplementedError
      end

      # Delete a key from the cache.
      #
      # @param key [String] Cache key
      # @return [void]
      def delete(key)
        raise NotImplementedError
      end

      # Check if a key exists and is not expired.
      #
      # @param key [String] Cache key
      # @return [Boolean]
      def exist?(key)
        raise NotImplementedError
      end

      # Clear cached entries. If namespace is given, only clear that domain.
      #
      # @param namespace [Symbol, nil] Cache domain to clear, or nil for all
      # @return [void]
      def clear(namespace: nil)
        raise NotImplementedError
      end

      # Read-through cache: return cached value or execute block and cache result.
      #
      # @note nil is treated as a cache miss. If the wrapped operation legitimately
      #   returns nil, every call will re-execute the block. Custom backend
      #   implementers should preserve this semantic — do not return nil for keys
      #   that were written with a non-nil value. This is acceptable for the
      #   built-in use cases (embeddings and formatted context are never nil).
      #
      # @param key [String] Cache key
      # @param ttl [Integer, nil] TTL in seconds
      # @yield Block that computes the value on cache miss
      # @return [Object] Cached or freshly computed value
      def fetch(key, ttl: nil)
        cached = read(key)
        return cached unless cached.nil?

        value = yield
        begin
          write(key, value, ttl: ttl)
        rescue StandardError => e
          warn("[CodebaseIndex] CacheStore#fetch write failed for #{key}: #{e.message}")
        end
        value
      end
    end

    # In-memory cache store with LRU eviction and TTL support.
    #
    # Zero external dependencies. Suitable for single-process use, development,
    # and as a fallback when Redis/SolidCache are not available. Thread-safe.
    #
    # @example
    #   store = InMemory.new(max_entries: 200)
    #   store.write("ci:emb:abc", [0.1, 0.2], ttl: 3600)
    #   store.read("ci:emb:abc") # => [0.1, 0.2]
    #
    class InMemory < CacheStore
      # @param max_entries [Integer] Maximum cached entries before LRU eviction
      def initialize(max_entries: 500)
        super()
        @max_entries = max_entries
        @entries = {}
        @access_order = []
        @mutex = Mutex.new
      end

      # Read a value, returning nil if missing or expired.
      #
      # @param key [String] Cache key
      # @return [Object, nil]
      def read(key)
        @mutex.synchronize do
          entry = @entries[key]
          return nil unless entry

          if entry[:expires_at] && Time.now > entry[:expires_at]
            evict_key(key)
            return nil
          end

          touch(key)
          entry[:value]
        end
      end

      # Write a value with optional TTL.
      #
      # @param key [String] Cache key
      # @param value [Object] Value to cache
      # @param ttl [Integer, nil] TTL in seconds
      # @return [void]
      def write(key, value, ttl: nil)
        @mutex.synchronize do
          evict_key(key) if @entries.key?(key)

          if @entries.size >= @max_entries
            oldest = @access_order.shift
            @entries.delete(oldest) if oldest
          end

          expires_at = ttl ? Time.now + ttl : nil
          @entries[key] = { value: value, expires_at: expires_at }
          @access_order.push(key)
        end
      end

      # Delete a key.
      #
      # @param key [String] Cache key
      # @return [void]
      def delete(key)
        @mutex.synchronize { evict_key(key) }
      end

      # Check if a key exists and is not expired.
      #
      # @param key [String] Cache key
      # @return [Boolean]
      def exist?(key)
        @mutex.synchronize do
          entry = @entries[key]
          return false unless entry
          return false if entry[:expires_at] && Time.now > entry[:expires_at]

          true
        end
      end

      # Clear entries. If namespace is given, only clear keys matching that domain.
      #
      # @param namespace [Symbol, nil] Domain to clear (:embeddings, :metadata, etc.)
      # @return [void]
      def clear(namespace: nil)
        @mutex.synchronize do
          if namespace
            prefix = "codebase_index:cache:#{namespace}:"
            keys_to_delete = @entries.keys.select { |k| k.start_with?(prefix) }
            keys_to_delete.each { |k| evict_key(k) }
          else
            @entries.clear
            @access_order.clear
          end
        end
      end

      # Number of entries currently in the cache (for testing/diagnostics).
      #
      # @return [Integer]
      def size
        @mutex.synchronize { @entries.size }
      end

      private

      # Remove a key from both the entry hash and access order.
      #
      # @param key [String]
      # @return [void]
      def evict_key(key)
        @entries.delete(key)
        @access_order.delete(key)
      end

      # Move a key to the end of the access order (most recently used).
      #
      # @param key [String]
      # @return [void]
      def touch(key)
        @access_order.delete(key)
        @access_order.push(key)
      end
    end
  end
end
