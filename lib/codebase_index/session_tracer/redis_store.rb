# frozen_string_literal: true

require 'json'
require_relative 'store'

module CodebaseIndex
  module SessionTracer
    # Redis-backed session store using Lists.
    #
    # Each session is stored as a Redis List keyed `codebase_index:session:{id}`.
    # RPUSH per request for append-only ordering. Native TTL for automatic cleanup.
    #
    # Requires the `redis` gem at runtime.
    #
    # @example
    #   store = RedisStore.new(redis: Redis.new, ttl: 3600)
    #   store.record("abc123", { controller: "OrdersController", action: "create" })
    #
    class RedisStore < Store
      KEY_PREFIX = 'codebase_index:session:'
      SESSIONS_KEY = 'codebase_index:sessions'

      # @param redis [Redis] A Redis client instance
      # @param ttl [Integer, nil] Time-to-live in seconds for session keys (nil = no expiry)
      def initialize(redis:, ttl: nil)
        super()
        unless defined?(::Redis)
          raise SessionTracerError, 'The redis gem is required for RedisStore. Add `gem "redis"` to your Gemfile.'
        end

        @redis = redis
        @ttl = ttl
      end

      # Append a request record to a session's Redis List.
      #
      # @param session_id [String] The session identifier
      # @param request_data [Hash] Request metadata to store
      # @return [void]
      def record(session_id, request_data)
        key = session_key(session_id)
        @redis.rpush(key, JSON.generate(request_data))
        @redis.expire(key, @ttl) if @ttl
        @redis.sadd(SESSIONS_KEY, session_id)
      end

      # Read all request records for a session.
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        key = session_key(session_id)
        @redis.lrange(key, 0, -1).filter_map do |json|
          JSON.parse(json)
        rescue JSON::ParserError
          nil
        end
      end

      # List recent session summaries.
      #
      # @param limit [Integer] Maximum number of sessions to return
      # @return [Array<Hash>] Session summaries
      def sessions(limit: 20)
        all_ids = @redis.smembers(SESSIONS_KEY)

        # Filter to sessions that still have data (TTL may have expired)
        active = all_ids.select { |id| @redis.exists?(session_key(id)) }

        # Remove expired session IDs from the set
        expired = all_ids - active
        expired.each { |id| @redis.srem(SESSIONS_KEY, id) } if expired.any?

        active.first(limit).map do |session_id|
          requests = read(session_id)
          {
            'session_id' => session_id,
            'request_count' => requests.size,
            'first_request' => requests.first&.fetch('timestamp', nil),
            'last_request' => requests.last&.fetch('timestamp', nil)
          }
        end
      end

      # Remove all data for a single session.
      #
      # @param session_id [String] The session identifier
      # @return [void]
      def clear(session_id)
        @redis.del(session_key(session_id))
        @redis.srem(SESSIONS_KEY, session_id)
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        all_ids = @redis.smembers(SESSIONS_KEY)
        all_ids.each { |id| @redis.del(session_key(id)) }
        @redis.del(SESSIONS_KEY)
      end

      private

      # @param session_id [String]
      # @return [String] Redis key for this session
      def session_key(session_id)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}"
      end
    end
  end
end
