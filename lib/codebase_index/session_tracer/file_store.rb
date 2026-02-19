# frozen_string_literal: true

require 'json'
require 'fileutils'
require_relative 'store'

module CodebaseIndex
  module SessionTracer
    # File-backed session store using JSONL (one JSON object per line).
    #
    # Sessions are stored as individual files in a configurable directory:
    #   {base_dir}/{session_id}.jsonl
    #
    # Append-only with file locking for concurrency safety. Zero external dependencies.
    #
    # @example
    #   store = FileStore.new(base_dir: "tmp/codebase_index/sessions")
    #   store.record("abc123", { controller: "PostsController", action: "create" })
    #   store.read("abc123") # => [{ "controller" => "PostsController", ... }]
    #
    class FileStore < Store
      # @param base_dir [String] Directory for session JSONL files
      def initialize(base_dir:)
        super()
        @base_dir = base_dir
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

        File.open(path, 'a') do |f|
          f.flock(File::LOCK_EX)
          f.write(line)
        end
      end

      # Read all request records for a session, ordered by file line order (timestamp).
      #
      # @param session_id [String] The session identifier
      # @return [Array<Hash>] Request records, oldest first
      def read(session_id)
        path = session_path(session_id)
        return [] unless File.exist?(path)

        File.readlines(path).filter_map do |line|
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
        pattern = File.join(@base_dir, '*.jsonl')
        files = Dir.glob(pattern).sort_by { |f| -File.mtime(f).to_f }

        files.first(limit).map do |file|
          session_id = File.basename(file, '.jsonl')
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
        path = session_path(session_id)
        FileUtils.rm_f(path)
      end

      # Remove all session data.
      #
      # @return [void]
      def clear_all
        pattern = File.join(@base_dir, '*.jsonl')
        Dir.glob(pattern).each { |f| File.delete(f) }
      end

      private

      # @param session_id [String]
      # @return [String] Full path to the session's JSONL file
      def session_path(session_id)
        File.join(@base_dir, "#{sanitize_session_id(session_id)}.jsonl")
      end
    end
  end
end
