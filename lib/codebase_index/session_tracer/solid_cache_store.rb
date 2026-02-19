# frozen_string_literal: true

require 'json'
require_relative 'store'

module CodebaseIndex
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
    class SolidCacheStore < Store
      KEY_PREFIX = 'codebase_index:session:'
      INDEX_KEY = 'codebase_index:session_index'

      # @param cache [ActiveSupport::Cache::Store] A SolidCache (or compatible) cache instance
      # @param expires_in [Integer, nil] Expiry time in seconds (nil = no expiry)
      def initialize(cache:, expires_in: nil)
        super()
        @cache = cache
        @expires_in = expires_in
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
        key = session_key(session_id)
        existing = @cache.read(key)
        requests = existing ? JSON.parse(existing) : []
        requests << request_data

        write_opts = @expires_in ? { expires_in: @expires_in } : {}
        @cache.write(key, JSON.generate(requests), **write_opts)

        update_index(session_id)
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
        index = read_index
        active = index.select { |id| @cache.exist?(session_key(id)) }

        # Clean up expired entries from the index
        write_index(active) if active.size != index.size

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
        @cache.delete(session_key(session_id))
        index = read_index
        index.delete(session_id)
        write_index(index)
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        index = read_index
        index.each { |id| @cache.delete(session_key(id)) }
        @cache.delete(INDEX_KEY)
      end

      private

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
        return if index.include?(session_id)

        index << session_id
        write_index(index)
      end
    end
  end
end
