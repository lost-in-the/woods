# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'store'

module Woods
  module SessionTracer
    # Redis-backed session store using Lists plus a recency ZSET.
    #
    # Each session is stored as a Redis List keyed `woods:session:{id}`.
    # RPUSH per request for append-only ordering. Native TTL for automatic
    # cleanup. The `woods:sessions` index is a ZSET scored by each session's
    # last request timestamp, so eviction touches O(log n) members instead
    # of re-reading every session's history (audit P4). A legacy SET left by
    # an earlier version is migrated on the first record.
    #
    # Requires the `redis` gem at runtime.
    #
    # @example
    #   store = RedisStore.new(redis: Redis.new, ttl: 3600)
    #   store.record("abc123", { controller: "OrdersController", action: "create" })
    #
    class RedisStore < Store
      KEY_PREFIX = 'woods:session:'
      # Recency index: ZSET of session_id => last-request epoch. Was a SET
      # before the zset migration; legacy deployments migrate through the
      # atomic script below.
      SESSIONS_KEY = 'woods:sessions'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000

      # Recency-index update for one record, executed server-side as one
      # atomic step: type check, legacy SET transfer, insertion of the
      # current member. Redis runs a script without interleaving, so two
      # writers racing a legacy index can neither observe the SET with one
      # writer and erase the other's members, nor fail with WRONGTYPE after
      # the other converted; a writer arriving on an already-converted (or
      # fresh) key takes the plain ZADD path of the same script.
      INDEX_UPDATE_SCRIPT = <<~LUA
        local kind = redis.call('TYPE', KEYS[1]).ok
        if kind == 'set' then
          local legacy = redis.call('SMEMBERS', KEYS[1])
          redis.call('DEL', KEYS[1])
          for _, member in ipairs(legacy) do
            redis.call('ZADD', KEYS[1], 0, member)
          end
        end
        redis.call('ZADD', KEYS[1], tonumber(ARGV[1]), ARGV[2])
        return 1
      LUA

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
        index_session(session_id, request_data)
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
        all_ids = @redis.zrange(SESSIONS_KEY, 0, -1)

        # Filter to sessions that still have data (TTL may have expired)
        active = all_ids.select { |id| @redis.exists?(session_key(id)) }

        # Remove expired session IDs from the index
        expired = all_ids - active
        expired.each { |id| @redis.zrem(SESSIONS_KEY, id) } if expired.any?

        # Redis sorted sets order by score, but a summary's last_request is
        # the payload timestamp of the session's last record — the same
        # source the score is derived from. Ordering the built summaries by
        # that field keeps the exact ordering contract (#218 / B-105) even
        # where a clock crept between score and payload.
        #
        # This still reads every active session rather than `limit` of them,
        # as before; the zset made *eviction* the O(log n) path.
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
        @redis.zrem(SESSIONS_KEY, session_id)
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        all_ids = @redis.zrange(SESSIONS_KEY, 0, -1)
        all_ids.each { |id| @redis.del(session_key(id)) }
        @redis.del(SESSIONS_KEY)
      end

      private

      # @param session_id [String]
      # @return [String] Redis key for this session
      def session_key(session_id)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}"
      end

      # Record the session in the recency index, scored by the request's own
      # timestamp so eviction order matches the last-request ordering
      # {#sessions} reports. The whole update — a legacy SET migration
      # included — runs as one atomic script (see {INDEX_UPDATE_SCRIPT}).
      #
      # @param session_id [String]
      # @param request_data [Hash]
      # @return [void]
      def index_session(session_id, request_data)
        @redis.eval(INDEX_UPDATE_SCRIPT, keys: [SESSIONS_KEY], argv: [recency_score(request_data), session_id])
      end

      # @param request_data [Hash]
      # @return [Float] Request timestamp as an epoch, or write time
      def recency_score(request_data)
        timestamp = request_data['timestamp'] if request_data.is_a?(Hash)
        timestamp.is_a?(String) ? Time.iso8601(timestamp).to_f : Time.now.to_f
      rescue ArgumentError
        Time.now.to_f
      end

      # Evict the oldest sessions once the recency index overflows
      # `@max_sessions`.
      #
      # The ZSET is scored by last request timestamp (see {#index_session}),
      # so the `overflow + 1` lowest-scoring members contain the oldest
      # `overflow` sessions other than the one just recorded. That matches
      # the FileStore twin's oldest-by-mtime eviction without reading any
      # session's history — the pre-zset implementation re-read every
      # candidate on every record once the cap was reached (audit P4).
      #
      # @param current_session_id [String] never evicted, even if oldest
      # @return [void]
      def prune_sessions(current_session_id)
        overflow = @redis.zcard(SESSIONS_KEY) - @max_sessions
        return unless overflow.positive?

        victims = @redis.zrange(SESSIONS_KEY, 0, overflow)
                        .reject { |id| id == current_session_id }
                        .first(overflow)

        victims.each do |id|
          @redis.del(session_key(id))
          @redis.zrem(SESSIONS_KEY, id)
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
