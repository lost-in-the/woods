# frozen_string_literal: true

require 'date'
require 'digest'
require 'json'
require 'pathname'
require 'set'
require_relative 'atomic_file'
require_relative 'git_log'

module Woods
  # The generation's commit table, `git_commits.json` (W-3, #753).
  #
  # Every HEAD-reachable commit in the window that touched at least one
  # indexed path, newest first, with the files it touched, plus a
  # `paths` table from each indexed path to the commits that touched it.
  # Co-change ("which files move with this one?") is answered from `paths`
  # alone: the commits of one path, and the other indexed paths those
  # commits list.
  #
  # The table is a pure function of the walked head, the indexed path set,
  # the window's first UTC day and the bounds, and records all of them, so
  # an incremental run that finds them unchanged keeps the published bytes
  # and one that does not rebuilds the whole table: full and incremental
  # runs publish the same file. An application with no readable git history
  # publishes no table at all; absence means "unknown", never "no commits".
  #
  # The walk is {GitLog}: the same HEAD selection, merge semantics,
  # `WOODS_GIT_DIR` override and nested-application prefix as the per-unit
  # `metadata.git` facts. Paths are relative to the application root.
  class GitCommitTable
    FILENAME = 'git_commits.json'
    SCHEMA_VERSION = 1

    # Default window, in days before the run's UTC date.
    DEFAULT_DAYS = 365
    # Default bound on published commits; older commits beyond it are dropped
    # and `truncated` is set.
    DEFAULT_MAX_COMMITS = 5_000
    # Default bound on the files listed for one commit; the rest are counted
    # in `files_omitted`.
    DEFAULT_MAX_FILES_PER_COMMIT = 100

    # Raw diff status letter => published status.
    STATUS = { 'A' => 'added', 'M' => 'modified', 'D' => 'deleted', 'T' => 'type_changed' }.freeze

    # The fields that decide the table's content; equal fields mean equal tables.
    KEY_FIELDS = %w[schema_version head since window_days max_commits max_files_per_commit
                    indexed_paths_sha256].freeze

    FORMAT = '%x00%H%x00%P%x00%an%x00%cI%x00%s%x00%b%x00'
    private_constant :FORMAT

    # The configured bounds, string-keyed as the table records them.
    #
    # @param config [Woods::Configuration, nil] nil uses the defaults
    # @return [Hash{String => Integer}]
    def self.settings(config = Woods.configuration)
      {
        'window_days' => config&.git_commit_table_days || DEFAULT_DAYS,
        'max_commits' => config&.git_commit_table_limit || DEFAULT_MAX_COMMITS,
        'max_files_per_commit' => config&.git_commit_table_files_limit || DEFAULT_MAX_FILES_PER_COMMIT
      }
    end

    # Whether a published table was built from exactly these inputs.
    #
    # @param table [Hash, nil] a published table
    # @param key [Hash] see {#key}
    # @return [Boolean]
    def self.current?(table, key)
      table.is_a?(Hash) && KEY_FIELDS.all? { |field| table[field] == key[field] }
    end

    # @param payload_dir [Pathname, String] generation payload directory
    # @param table [Hash] result of {#build}
    # @param durable [Boolean] fsync the file before returning
    # @return [void]
    def self.write(payload_dir, table, durable:)
      AtomicFile.write(Pathname(payload_dir).join(FILENAME), JSON.generate(table), durable: durable)
    end

    # @param payload_dir [Pathname, String] generation payload directory
    # @return [Hash, nil] the published table, or nil when the generation has none
    # @raise [JSON::ParserError] when the file does not parse
    def self.read(payload_dir)
      path = Pathname(payload_dir).join(FILENAME)
      path.file? ? JSON.parse(AtomicFile.read(path)) : nil
    end

    # Remove the generation's table, if it has one.
    #
    # @param payload_dir [Pathname, String] generation payload directory
    # @return [void]
    def self.delete(payload_dir)
      path = Pathname(payload_dir).join(FILENAME)
      path.delete if path.exist? || path.symlink?
    end

    # @param root [String, Pathname] application root
    # @param logger [#warn]
    # @param settings [Hash{String => Integer}] see {.settings}
    # @param today [Date] the run's UTC date; the window starts `window_days` before it
    def initialize(root:, logger:, settings:, today: Time.now.utc.to_date)
      @log = GitLog.new(root: root)
      @logger = logger
      @settings = settings
      @since = (today - settings.fetch('window_days')).iso8601
    end

    # The inputs a table built now would record.
    #
    # @param paths [Array<String>] indexed, application-relative paths
    # @param head [String] the resolved HEAD sha
    # @return [Hash{String => Object}]
    def key(paths, head:)
      { 'schema_version' => SCHEMA_VERSION, 'head' => head, 'since' => @since,
        'window_days' => @settings.fetch('window_days'), 'max_commits' => @settings.fetch('max_commits'),
        'max_files_per_commit' => @settings.fetch('max_files_per_commit'),
        'indexed_paths_sha256' => Digest::SHA256.hexdigest(paths.uniq.sort.join("\n")) }
    end

    # Walk +head+ and build the table.
    #
    # @param paths [Array<String>] indexed, application-relative paths
    # @param head [String] the resolved HEAD sha; walked instead of `HEAD`
    #   so the table matches the head it records
    # @return [Hash, nil] the table, or nil when the history could not be read completely
    def build(paths, head:)
      parser = Parser.new(prefix: @log.repository_prefix, indexed: paths.to_set, settings: @settings)
      @log.stream(format: FORMAT, since: "#{@since}T00:00:00Z", revision: head) { |io| parser.parse(io) }
      key(paths, head: head).merge(parser.result)
    rescue StandardError => e
      @logger.warn('[Woods] Git commit table omitted: history could not be read completely. ' \
                   'Git 2.31 or newer is required; check the application repository and git installation. ' \
                   "(#{e.class})")
      nil
    end

    # Turns the walk's records into commit rows and the path table.
    class Parser
      # @param prefix [String] the application's binary repository prefix
      # @param indexed [Set<String>] indexed, application-relative paths
      # @param settings [Hash{String => Integer}]
      def initialize(prefix:, indexed:, settings:)
        @prefix = prefix
        @indexed = indexed
        @max_commits = settings.fetch('max_commits')
        @max_files = settings.fetch('max_files_per_commit')
        @rows = []
        @truncated = false
      end

      # @param io [IO] the walk's stdout
      # @return [void]
      # @raise [GitLog::ReadError] on a malformed or incomplete stream
      def parse(io)
        current = nil
        while (field = GitLog.token(io))
          next if field.empty?

          if field.match?(GitLog::SHA)
            finish(current)
            current = read_commit(io, field)
          elsif field.match?(GitLog::RAW)
            record_path(io, current, field)
          else
            raise GitLog::ReadError, 'unexpected history record'
          end
        end
        finish(current)
      end

      # @return [Hash] `truncated`, `commits` and `paths`
      def result
        { 'truncated' => @truncated, 'commits' => @rows.map(&:first), 'paths' => path_table }
      end

      private

      def read_commit(io, sha)
        parents, author, date, message, description = Array.new(5) { GitLog.token(io) }
        raise GitLog::ReadError, 'incomplete commit header' unless description

        { 'sha' => sha, 'parents' => parents.split, 'author' => text(author), 'date' => date,
          'message' => text(message), 'description' => text(description).strip, files: [] }
      end

      def record_path(io, commit, header)
        path = GitLog.token(io)
        raise GitLog::ReadError, 'incomplete path record' unless commit && path
        return unless path.start_with?(@prefix)

        relative = path.byteslice(@prefix.bytesize..).force_encoding(Encoding::UTF_8)
        commit[:files] << { 'path' => relative, 'status' => STATUS.fetch(header[-1], header[-1]) }
      end

      # Admit a finished commit when it touched an indexed path. A path that
      # is not valid UTF-8 cannot be published as JSON text; it is counted in
      # `files_omitted` like a file beyond the bound.
      def finish(commit)
        return unless commit

        files = commit.delete(:files)
        valid = files.select { |file| file['path'].valid_encoding? }
        touched = valid.map { |file| file['path'] }.select { |path| @indexed.include?(path) }.uniq
        return if touched.empty?
        return @truncated = true if @rows.size >= @max_commits

        listed = valid.first(@max_files)
        @rows << [commit.merge('files' => listed, 'files_omitted' => files.size - listed.size), touched]
      end

      def path_table
        table = Hash.new { |hash, key| hash[key] = [] }
        @rows.each { |row, touched| touched.each { |path| table[path] << row['sha'] } }
        table.sort.to_h
      end

      def text(value)
        value.force_encoding(Encoding::UTF_8).scrub
      end
    end
    private_constant :Parser
  end
end
