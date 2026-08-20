# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'tempfile'
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
    class FileStore < Store # rubocop:disable Metrics/ClassLength
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
        line = "#{JSON.generate(request_data)}\n"

        with_store_lock do
          path = migrate_legacy_session!(session_id)
          lines = File.exist?(path) ? File.readlines(path).last(@max_requests_per_session - 1) : []
          atomic_replace(path, (lines << line).join)
          prune_sessions!
        end
      end

      # Read all request records for a session, ordered by file line order (timestamp).
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        lines = with_store_lock do
          path = migrate_legacy_session!(session_id)
          return [] unless File.exist?(path)

          if expired?(path)
            FileUtils.rm_f(path)
            return []
          end

          File.readlines(path)
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
        files = with_store_lock do
          migrate_legacy_sessions!
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
        with_store_lock do
          FileUtils.rm_f(session_path(session_id))
          FileUtils.rm_f(legacy_session_path(session_id))
        end
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        with_store_lock { session_files.each { |file| File.delete(file) } }
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

      def with_store_lock
        @mutex.synchronize do
          File.open(File.join(@base_dir, '.woods-session-store.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            yield
          end
        end
      end

      def legacy_session_path(session_id)
        raw = session_id.to_s
        return unless raw.match?(/\A[a-zA-Z0-9_-]+\z/)

        File.join(@base_dir, "#{raw}.jsonl")
      end

      def migrate_legacy_session!(session_id)
        target = session_path(session_id)
        legacy = legacy_session_path(session_id)
        return target unless legacy && File.exist?(legacy)

        if File.exist?(target)
          atomic_replace(target, File.read(legacy) + File.read(target))
          FileUtils.rm_f(legacy)
        else
          File.rename(legacy, target)
          fsync_parent
        end
        target
      end

      def migrate_legacy_sessions!
        session_files.each do |path|
          basename = File.basename(path, '.jsonl')
          migrate_legacy_session!(basename) unless basename.start_with?('b64.')
        end
      end

      def atomic_replace(path, content)
        temp = Tempfile.new([".#{File.basename(path)}-", '.tmp'], @base_dir)
        temp.chmod(0o600)
        temp.write(content)
        temp.flush
        temp.fsync
        temp.close
        File.rename(temp.path, path)
        fsync_parent
      ensure
        temp&.close
        temp&.unlink
      end

      def fsync_parent
        File.open(@base_dir, File::RDONLY, &:fsync)
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EISDIR
        nil
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
