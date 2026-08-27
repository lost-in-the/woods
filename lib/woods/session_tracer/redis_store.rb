# frozen_string_literal: true

require 'json'
require_relative 'store'

module Woods
  module SessionTracer
    # Redis-backed session store using Lists.
    #
    # Each session is stored as a Redis List keyed `woods:session:{id}`.
    # RPUSH per request for append-only ordering. Native TTL for automatic cleanup.
    #
    # Requires the `redis` gem at runtime.
    #
    # @example
    #   store = RedisStore.new(redis: Redis.new, ttl: 3600)
    #   store.record("abc123", { controller: "OrdersController", action: "create" })
    #
    class RedisStore < Store
      KEY_PREFIX = 'woods:session:'
      SESSIONS_KEY = 'woods:sessions'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000

      # @param redis [Redis] A Redis client instance
      # @param ttl [Integer, nil] Time-to-live in seconds for session keys (nil = no expiry)
      def initialize(redis:, ttl: nil, max_sessions: DEFAULT_MAX_SESSIONS,
                     max_requests_per_session: DEFAULT_MAX_REQUESTS)
        super()
        unless defined?(::Redis)
          raise SessionTracerError, 'The redis gem is required for RedisStore. Add `gem "redis"` to your Gemfile.'
        end

        @redis = redis
        @ttl = ttl
        @max_sessions = max_sessions
        @max_requests_per_session = max_requests_per_session
      end

      # Append a request record to a session's Redis List.
      #
      # @param session_id [String] The session identifier
      # @param request_data [Hash] Request metadata to store
      # @return [void]
      def record(session_id, request_data)
        key = session_key(session_id)
        @redis.rpush(key, JSON.generate(request_data))
        @redis.ltrim(key, -@max_requests_per_session, -1)
        @redis.expire(key, @ttl) if @ttl
        @redis.sadd(SESSIONS_KEY, session_id)
        prune_sessions(session_id)
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

        # Redis sets are unordered, so `active.first(limit)` returned arbitrary
        # members — callers asking for "recent sessions" got a random sample,
        # while the FileStore twin genuinely sorts by mtime. Build the
        # summaries, then order by last request descending so both stores
        # answer the same question.
        #
        # This reads every active session rather than `limit` of them. That is
        # the price of ordering a set; the alternative is a sorted set keyed on
        # write time, which is a storage-format change this does not warrant.
        active
          .map { |session_id| session_summary(session_id, read(session_id)) }
          .sort_by { |summary| recency_key(summary) }
          .reverse
          .first(limit)
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

      # Evict the oldest sessions once the active-session index overflows
      # `@max_sessions`.
      #
      # Redis sets are unordered, so `ids.first(overflow)` evicted arbitrary
      # members — a session recorded seconds ago could be dropped while one
      # untouched for hours survived. Ordering by last recorded activity
      # matches the FileStore twin's oldest-by-mtime eviction.
      #
      # This reads every candidate session's history to find its last
      # timestamp, same tradeoff as {#sessions}: the alternative is a sorted
      # set keyed on write time, a storage-format change this does not
      # warrant.
      #
      # @param current_session_id [String] never evicted, even if oldest
      # @return [void]
      def prune_sessions(current_session_id)
        ids = @redis.smembers(SESSIONS_KEY)
        overflow = ids.size - @max_sessions
        return unless overflow.positive?

        victims = ids
                  .reject { |id| id == current_session_id }
                  .sort_by { |id| recency_key(session_summary(id, read(id))) }
                  .first(overflow)

        victims.each do |id|
          @redis.del(session_key(id))
          @redis.srem(SESSIONS_KEY, id)
        end
      end

      # Sort key for {#sessions}: most recent request first.
      #
      # Timestamps are ISO-8601 strings, which sort correctly as strings. A
      # session with no requests (all entries expired mid-read) sorts last
      # rather than raising on a nil comparison.
      #
      # @param summary [Hash]
      # @return [String]
      def recency_key(summary)
        summary['last_request'].to_s
      end
    end
  end
end
