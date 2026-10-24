# frozen_string_literal: true

require 'json'
require 'pathname'
require 'set'
require_relative '../git_commit_table'

module Woods
  class PublishedIndex
    # Read-only view of one generation's `git_commits.json` (W-3).
    #
    # Built by {PublishedIndex#git_commits}; see {Woods::GitCommitTable} for
    # how the table is written. Commit rows are string-keyed hashes exactly as
    # published, newest first. Paths are application-relative, as unit
    # `file_path` values are. Everything is frozen.
    #
    # Co-change comes from the `paths` table alone: the commits that touched
    # one set of paths, and every other indexed path those commits touched.
    class CommitTable
      # Shortest sha prefix {#commit} resolves.
      MIN_PREFIX = 4

      # Load the table from a payload directory.
      #
      # @param payload_dir [Pathname]
      # @return [CommitTable, nil] nil when the generation publishes no table
      # @raise [CorruptArtifactError] when the file is a symlink, does not
      #   parse, or is not a schema version 1 table
      def self.load(payload_dir)
        path = Pathname(payload_dir).join(GitCommitTable::FILENAME)
        raise CorruptArtifactError, "symlinked #{GitCommitTable::FILENAME}" if path.symlink?
        return nil unless path.file?

        new(JSON.parse(path.binread.force_encoding(Encoding::UTF_8)))
      rescue JSON::ParserError => e
        raise CorruptArtifactError, "#{GitCommitTable::FILENAME} does not parse: #{e.message}"
      end

      # @param data [Hash] a parsed table
      # @raise [CorruptArtifactError] when +data+ is not a schema version 1 table
      def initialize(data)
        validate!(data)
        @data = deep_freeze(data)
        @by_sha = @data['commits'].to_h { |row| [row['sha'], row] }.freeze
      end

      # @return [String] the HEAD sha the table was walked from
      def head
        @data['head']
      end

      # @return [String] the window's first UTC day (`YYYY-MM-DD`)
      def since
        @data['since']
      end

      # @return [Integer] the configured window, in days
      def window_days
        @data['window_days']
      end

      # @return [Integer] the configured commit bound
      def max_commits
        @data['max_commits']
      end

      # @return [Integer] the configured per-commit file bound
      def max_files_per_commit
        @data['max_files_per_commit']
      end

      # @return [Boolean] whether older commits in the window were dropped by the bound
      def truncated?
        @data['truncated']
      end

      # @return [Array<Hash>] every published commit, newest first
      def commits
        @data['commits']
      end

      # @return [Hash{String => Array<String>}] indexed path => shas, newest first
      def paths
        @data['paths']
      end

      # @return [Hash] the table exactly as published
      def to_h
        @data
      end

      # One commit by full sha or a unique prefix of at least {MIN_PREFIX}
      # characters (the 8-character shas of `metadata.git.recent_commits`
      # resolve here).
      #
      # @param sha [String]
      # @return [Hash, nil] nil when absent or ambiguous
      def commit(sha)
        sha = sha.to_s
        return @by_sha[sha] if @by_sha.key?(sha)
        return nil if sha.length < MIN_PREFIX

        matches = @by_sha.keys.select { |key| key.start_with?(sha) }
        matches.one? ? @by_sha[matches.first] : nil
      end

      # Commits that touched any of +paths+, newest first.
      #
      # @param paths [Array<String>] application-relative paths
      # @return [Array<Hash>]
      def commits_for(*paths)
        shas = paths.flatten.flat_map { |path| self.paths.fetch(path, []) }.to_set
        commits.select { |row| shas.include?(row['sha']) }
      end

      # The indexed paths one commit touched.
      #
      # @param sha [String] full sha
      # @return [Array<String>] sorted
      def indexed_paths_for(sha)
        touched_by_sha.fetch(sha, [])
      end

      # Indexed paths that changed in the same commits as +paths+, with how
      # many of those commits each shared, most first (ties by path).
      #
      # @param paths [Array<String>] application-relative paths
      # @return [Array<Hash>] `{ 'path' =>, 'commits' => }`, excluding +paths+
      def co_changes(*paths)
        own = paths.flatten.to_set
        counts = Hash.new(0)
        commits_for(*own).each do |row|
          indexed_paths_for(row['sha']).each { |path| counts[path] += 1 unless own.include?(path) }
        end
        counts.sort_by { |path, count| [-count, path] }.map { |path, count| { 'path' => path, 'commits' => count } }
      end

      private

      def touched_by_sha
        @touched_by_sha ||= begin
          map = Hash.new { |hash, key| hash[key] = [] }
          paths.each { |path, shas| shas.each { |sha| map[sha] << path } }
          map.transform_values { |list| list.sort.freeze }.freeze
        end
      end

      def validate!(data)
        return if data.is_a?(Hash) && data['schema_version'] == GitCommitTable::SCHEMA_VERSION && valid_rows?(data)

        version = data.is_a?(Hash) ? data['schema_version'].inspect : 'none'
        raise CorruptArtifactError, "#{GitCommitTable::FILENAME} is not a schema version 1 table (#{version})"
      end

      def valid_rows?(data)
        data['paths'].is_a?(Hash) && data['commits'].is_a?(Array) &&
          data['commits'].all? { |row| row.is_a?(Hash) && row['sha'].is_a?(String) }
      end

      def deep_freeze(value)
        case value
        when Hash then value.each_value { |item| deep_freeze(item) }.freeze
        when Array then value.each { |item| deep_freeze(item) }.freeze
        else value.freeze
        end
      end
    end
  end
end
