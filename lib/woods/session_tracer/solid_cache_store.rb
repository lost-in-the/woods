# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'store'

module Woods
  module SessionTracer
    # SolidCache-backed session store.
    #
    # Uses SolidCache key-value storage with `expires_in`. Single JSON blob
    # per session (read-modify-write pattern). Requires the `solid_cache` gem.
    #
    # @example
    #   store = SolidCacheStore.new(cache: SolidCache::Store.new, expires_in: 3600)
    #   store.record("abc123", { controller: "OrdersController", action: "create" })
    #
    class SolidCacheStore < Store # rubocop:disable Metrics/ClassLength
      KEY_PREFIX = 'woods:session:'
      INDEX_KEY = 'woods:session_index'
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000
      LOCK_KEY = 'woods:session_lock'
      DEFAULT_LOCK_LEASE = 5.0
      DEFAULT_LOCK_TIMEOUT = 2.0
      DEFAULT_LOCK_RETRY_INTERVAL = 0.01

      class LockTimeout < Woods::Error; end

      # @param cache [ActiveSupport::Cache::Store] A SolidCache (or compatible) cache instance
      # @param expires_in [Integer, nil] Expiry time in seconds (nil = no expiry)
      def initialize(cache:, expires_in: nil, max_sessions: DEFAULT_MAX_SESSIONS, # rubocop:disable Metrics/ParameterLists
                     max_requests_per_session: DEFAULT_MAX_REQUESTS,
                     lock_lease: DEFAULT_LOCK_LEASE, lock_timeout: DEFAULT_LOCK_TIMEOUT,
                     lock_retry_interval: DEFAULT_LOCK_RETRY_INTERVAL)
        super()
        @cache = cache
        @expires_in = expires_in
        @max_sessions = max_sessions
        @max_requests_per_session = max_requests_per_session
        @lock_lease = Float(lock_lease)
        @lock_timeout = Float(lock_timeout)
        @lock_retry_interval = Float(lock_retry_interval)
      end

      # Append a request record to a session (read-modify-write).
      #
      # NOTE: Not atomic — concurrent writes to the same session may lose data.
      # Acceptable for development tracing. For high-concurrency tracing, use
      # RedisStore (RPUSH is atomic) or FileStore (LOCK_EX).
      #
      # @param session_id [String] The session identifier
      # @param request_data [Hash] Request metadata to store
      # @return [void]
      def record(session_id, request_data)
        JSON.generate(request_data)
        with_backend_lock do
          key = session_key(session_id)
          existing = @cache.read(key)
          requests = existing ? JSON.parse(existing) : []
          requests << request_data
          requests = requests.last(@max_requests_per_session)

          write_opts = @expires_in ? { expires_in: @expires_in } : {}
          @cache.write(key, JSON.generate(requests), **write_opts)

          update_index(session_id)
        end
      end

      # Read all request records for a session.
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        key = session_key(session_id)
        raw = @cache.read(key)
        return [] unless raw

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      # List recent session summaries.
      #
      # @param limit [Integer] Maximum number of sessions to return
      # @return [Array<Hash>] Session summaries
      def sessions(limit: 20)
        with_backend_lock do
          index = read_index
          active = index.select { |id| @cache.exist?(session_key(id)) }

          write_index(active) if active.size != index.size

          active.first(limit).map do |session_id|
            session_summary(session_id, read(session_id))
          end
        end
      end

      # Remove all data for a single session.
      #
      # @param session_id [String] The session identifier
      # @return [void]
      def clear(session_id)
        with_backend_lock do
          @cache.delete(session_key(session_id))
          index = read_index
          index.delete(session_id)
          write_index(index)
        end
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        with_backend_lock do
          index = read_index
          index.each { |id| @cache.delete(session_key(id)) }
          @cache.delete(INDEX_KEY)
        end
      end

      private

      def with_backend_lock
        token = SecureRandom.uuid
        deadline = monotonic_now + @lock_timeout
        until @cache.write(LOCK_KEY, token, unless_exist: true, expires_in: @lock_lease)
          if monotonic_now >= deadline
            raise LockTimeout, "Timed out acquiring SolidCache session lock after #{@lock_timeout}s"
          end

          sleep(@lock_retry_interval)
        end
        yield
      ensure
        @cache.delete(LOCK_KEY) if token && @cache.read(LOCK_KEY) == token
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # @param session_id [String]
      # @return [String] Cache key for this session
      def session_key(session_id)
        "#{KEY_PREFIX}#{sanitize_session_id(session_id)}"
      end

      # Read the session index (list of known session IDs).
      #
      # @return [Array<String>]
      def read_index
        raw = @cache.read(INDEX_KEY)
        return [] unless raw

        JSON.parse(raw)
      rescue JSON::ParserError
        []
      end

      # Write the session index.
      #
      # @param ids [Array<String>]
      def write_index(ids)
        @cache.write(INDEX_KEY, JSON.generate(ids))
      end

      # Add a session ID to the index if not already present.
      #
      # @param session_id [String]
      def update_index(session_id)
        index = read_index
        index.delete(session_id)
        index << session_id
        stale = index.shift([index.size - @max_sessions, 0].max)
        stale.each { |id| @cache.delete(session_key(id)) }
        write_index(index)
      end
    end
  end
end
