# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'store'

module Woods
  module SessionTracer
    # File-backed session store using JSONL (one JSON object per line).
    #
    # Sessions are stored as individual files in a configurable directory:
    #   {base_dir}/{session_id}.jsonl
    #
    # Append-only with file locking for concurrency safety. Zero external dependencies.
    #
    # @example
    #   store = FileStore.new(base_dir: "tmp/woods/sessions")
    #   store.record("abc123", { controller: "PostsController", action: "create" })
    #   store.read("abc123") # => [{ "controller" => "PostsController", ... }]
    #
    class FileStore < Store
      DEFAULT_MAX_SESSIONS = 1_000
      DEFAULT_MAX_REQUESTS = 1_000

      # @param base_dir [String] Directory for session JSONL files
      def initialize(base_dir:, ttl: nil, max_sessions: DEFAULT_MAX_SESSIONS,
                     max_requests_per_session: DEFAULT_MAX_REQUESTS, clock: -> { Time.now })
        super()
        validate_limit!(:max_sessions, max_sessions)
        validate_limit!(:max_requests_per_session, max_requests_per_session)
        @base_dir = base_dir
        @ttl = ttl
        @max_sessions = max_sessions
        @max_requests_per_session = max_requests_per_session
        @clock = clock
        @mutex = Mutex.new
        FileUtils.mkdir_p(@base_dir)
      end

      # Append a request record to a session's JSONL file.
      #
      # Uses file locking (LOCK_EX) for concurrency safety.
      #
      # @param session_id [String] The session identifier
      # @param request_data [Hash] Request metadata to store
      # @return [void]
      def record(session_id, request_data)
        path = session_path(session_id)
        line = "#{JSON.generate(request_data)}\n"

        @mutex.synchronize do
          File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
            file.flock(File::LOCK_EX)
            lines = file.readlines.last(@max_requests_per_session - 1)
            lines << line
            file.rewind
            file.truncate(0)
            file.write(lines.join)
          end
          prune_sessions!
        end
      end

      # Read all request records for a session, ordered by file line order (timestamp).
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        path = session_path(session_id)
        lines = @mutex.synchronize do
          return [] unless File.exist?(path)

          if expired?(path)
            FileUtils.rm_f(path)
            return []
          end

          File.open(path, 'r') do |file|
            file.flock(File::LOCK_SH)
            file.readlines
          end
        end
        lines.filter_map do |line|
          stripped = line.strip
          next if stripped.empty?

          JSON.parse(stripped)
        rescue JSON::ParserError
          nil
        end
      end

      # List recent session summaries, sorted by last modification time (newest first).
      #
      # @param limit [Integer] Maximum number of sessions to return
      # @return [Array<Hash>] Session summaries
      def sessions(limit: 20)
        files = @mutex.synchronize do
          prune_expired!
          session_files.sort_by { |file| -File.mtime(file).to_f }.first(limit)
        end

        files.map do |file|
          session_id = restore_session_id(File.basename(file, '.jsonl'))
          session_summary(session_id, read(session_id))
        end
      end

      # Remove all data for a single session.
      #
      # @param session_id [String] The session identifier
      # @return [void]
      def clear(session_id)
        path = session_path(session_id)
        @mutex.synchronize { FileUtils.rm_f(path) }
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        @mutex.synchronize { session_files.each { |file| File.delete(file) } }
      end

      private

      # @param session_id [String]
      # @return [String] Full path to the session's JSONL file
      def session_path(session_id)
        File.join(@base_dir, "#{sanitize_session_id(session_id)}.jsonl")
      end

      def session_files
        Dir.glob(File.join(@base_dir, '*.jsonl'))
      end

      def expired?(path)
        @ttl && @clock.call >= File.mtime(path) + @ttl
      end

      def prune_expired!
        session_files.each { |file| FileUtils.rm_f(file) if expired?(file) }
      end

      def prune_sessions!
        prune_expired!
        stale = session_files.sort_by { |file| -File.mtime(file).to_f }.drop(@max_sessions)
        stale.each { |file| FileUtils.rm_f(file) }
      end

      def validate_limit!(name, value)
        return if value.is_a?(Integer) && value.positive?

        raise ArgumentError, "#{name} must be a positive Integer"
      end
    end
  end
end
