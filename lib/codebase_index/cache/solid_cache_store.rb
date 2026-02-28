# frozen_string_literal: true

require 'json'
require 'logger'
require_relative 'cache_store'

module CodebaseIndex
  module Cache
    # SolidCache-backed (or any ActiveSupport::Cache::Store) cache store.
    #
    # Delegates to a Rails-compatible cache backend. Values are JSON-serialized
    # to avoid Marshal dependency issues across Ruby versions. TTL is passed
    # as `expires_in:` to the underlying cache.
    #
    # @example With SolidCache
    #   store = SolidCacheStore.new(cache: SolidCache::Store.new, default_ttl: 3600)
    #   store.write("ci:emb:abc", [0.1, 0.2], ttl: 86_400)
    #   store.read("ci:emb:abc") # => [0.1, 0.2]
    #
    # @example With Rails.cache (any backend)
    #   store = SolidCacheStore.new(cache: Rails.cache)
    #
    class SolidCacheStore < CacheStore
      # @param cache [ActiveSupport::Cache::Store] A SolidCache or compatible cache instance
      # @param default_ttl [Integer, nil] Default TTL in seconds (nil = no expiry)
      def initialize(cache:, default_ttl: nil)
        super()
        @cache = cache
        @default_ttl = default_ttl
      end

      # Read a value from the cache.
      #
      # @param key [String] Cache key
      # @return [Object, nil] Deserialized value or nil
      def read(key)
        raw = @cache.read(key)
        return nil unless raw

        JSON.parse(raw)
      rescue JSON::ParserError
        delete_silently(key)
        nil
      rescue StandardError => e
        logger.warn("[CodebaseIndex] SolidCacheStore#read failed for #{key}: #{e.message}")
        nil
      end

      # Write a value with optional TTL.
      #
      # @param key [String] Cache key
      # @param value [Object] Value to cache (must be JSON-serializable)
      # @param ttl [Integer, nil] TTL in seconds (falls back to default_ttl)
      # @return [void]
      def write(key, value, ttl: nil)
        serialized = JSON.generate(value)
        effective_ttl = ttl || @default_ttl

        opts = effective_ttl ? { expires_in: effective_ttl } : {}
        @cache.write(key, serialized, **opts)
      rescue StandardError => e
        logger.warn("[CodebaseIndex] SolidCacheStore#write failed for #{key}: #{e.message}")
        nil
      end

      # Delete a key from the cache.
      #
      # @param key [String] Cache key
      # @return [void]
      def delete(key)
        @cache.delete(key)
      rescue StandardError => e
        logger.warn("[CodebaseIndex] SolidCacheStore#delete failed for #{key}: #{e.message}")
        nil
      end

      # Check if a key exists in the cache.
      #
      # @param key [String] Cache key
      # @return [Boolean]
      def exist?(key)
        @cache.exist?(key)
      rescue StandardError => e
        logger.warn("[CodebaseIndex] SolidCacheStore#exist? failed for #{key}: #{e.message}")
        false
      end

      # Clear cached entries by namespace or all codebase_index cache keys.
      #
      # Uses `delete_matched` if the underlying cache supports it (Redis, Memcached).
      # Falls back to a no-op if pattern deletion is not available (some backends
      # like SolidCache don't support wildcard deletion).
      #
      # @param namespace [Symbol, nil] Domain to clear, or nil for all cache keys
      # @return [void]
      def clear(namespace: nil)
        pattern = if namespace
                    "codebase_index:cache:#{namespace}:*"
                  else
                    'codebase_index:cache:*'
                  end

        unless @cache.respond_to?(:delete_matched)
          logger.warn("[CodebaseIndex] Cache#clear(namespace: #{namespace.inspect}) is a no-op: " \
                      "backend #{@cache.class} does not support delete_matched")
          return
        end

        @cache.delete_matched(pattern)
      rescue StandardError => e
        logger.warn("[CodebaseIndex] SolidCacheStore#clear failed: #{e.message}")
        nil
      end

      private

      def logger
        @logger ||= defined?(Rails) ? Rails.logger : Logger.new($stderr)
      end

      def delete_silently(key)
        @cache.delete(key)
      rescue StandardError
        nil
      end
    end
  end
end
