# frozen_string_literal: true

require 'json'
require 'logger'
require_relative 'cache_store'

module CodebaseIndex
  module Cache
    # Redis-backed cache store using GET/SET with TTL.
    #
    # Uses simple key-value operations (not Lists like SessionTracer::RedisStore).
    # Values are JSON-serialized on write and deserialized on read. TTL is
    # enforced natively by Redis via the EX option on SET.
    #
    # Requires the `redis` gem at runtime.
    #
    # @example
    #   store = RedisCacheStore.new(redis: Redis.new, default_ttl: 3600)
    #   store.write("ci:emb:abc", [0.1, 0.2], ttl: 86_400)
    #   store.read("ci:emb:abc") # => [0.1, 0.2]
    #
    class RedisCacheStore < CacheStore
      # @param redis [Redis] A Redis client instance
      # @param default_ttl [Integer, nil] Default TTL in seconds when none specified (nil = no expiry)
      # @raise [ConfigurationError] if the redis gem is not loaded
      def initialize(redis:, default_ttl: nil)
        super()
        unless defined?(::Redis)
          raise ConfigurationError,
                'The redis gem is required for RedisCacheStore. Add `gem "redis"` to your Gemfile.'
        end

        @redis = redis
        @default_ttl = default_ttl
      end

      # Read a value from Redis.
      #
      # @param key [String] Cache key
      # @return [Object, nil] Deserialized value or nil
      def read(key)
        raw = @redis.get(key)
        return nil unless raw

        JSON.parse(raw)
      rescue JSON::ParserError
        delete_silently(key)
        nil
      rescue ::Redis::BaseError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        logger.warn("[CodebaseIndex] RedisCacheStore#read failed for #{key}: #{e.message}")
        nil
      end

      # Write a value to Redis with optional TTL.
      #
      # @param key [String] Cache key
      # @param value [Object] Value to cache (must be JSON-serializable)
      # @param ttl [Integer, nil] TTL in seconds (falls back to default_ttl)
      # @return [void]
      def write(key, value, ttl: nil)
        serialized = JSON.generate(value)
        effective_ttl = ttl || @default_ttl

        if effective_ttl
          @redis.set(key, serialized, ex: effective_ttl)
        else
          @redis.set(key, serialized)
        end
      rescue ::Redis::BaseError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        logger.warn("[CodebaseIndex] RedisCacheStore#write failed for #{key}: #{e.message}")
        nil
      end

      # Delete a key from Redis.
      #
      # @param key [String] Cache key
      # @return [void]
      def delete(key)
        @redis.del(key)
      rescue ::Redis::BaseError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        logger.warn("[CodebaseIndex] RedisCacheStore#delete failed for #{key}: #{e.message}")
        nil
      end

      # Check if a key exists in Redis.
      #
      # @param key [String] Cache key
      # @return [Boolean]
      def exist?(key)
        @redis.exists?(key)
      rescue ::Redis::BaseError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        logger.warn("[CodebaseIndex] RedisCacheStore#exist? failed for #{key}: #{e.message}")
        false
      end

      # Clear cached entries by namespace or all codebase_index cache keys.
      #
      # Uses SCAN (not KEYS) to avoid blocking Redis on large keyspaces.
      #
      # @param namespace [Symbol, nil] Domain to clear, or nil for all cache keys
      # @return [void]
      def clear(namespace: nil)
        pattern = if namespace
                    "codebase_index:cache:#{namespace}:*"
                  else
                    'codebase_index:cache:*'
                  end

        cursor = '0'
        loop do
          cursor, keys = @redis.scan(cursor, match: pattern, count: 100)
          @redis.del(*keys) if keys.any?
          break if cursor == '0'
        end
      rescue ::Redis::BaseError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        logger.warn("[CodebaseIndex] RedisCacheStore#clear failed: #{e.message}")
        nil
      end

      private

      def logger
        @logger ||= defined?(Rails) ? Rails.logger : Logger.new($stderr)
      end

      def delete_silently(key)
        @redis.del(key)
      rescue StandardError
        nil
      end
    end
  end
end
