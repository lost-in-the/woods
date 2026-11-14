# frozen_string_literal: true

require 'open3'
require_relative 'git_command'

module Woods
  # The HEAD history walk shared by {GitHistory} (per-unit `metadata.git`)
  # and {GitCommitTable} (the generation's `git_commits.json`).
  #
  # One `git log` over HEAD-reachable commits, without pathspec
  # simplification, as raw NUL-framed records: a commit header in the
  # caller's format, then one raw diff record per touched path. Merge diffs
  # compare against the first parent while traversal still visits every
  # parent. Requires Git 2.31 or newer. Every command is built by
  # {GitCommand}, so it is rooted at the application and honours
  # `WOODS_GIT_DIR`.
  class GitLog
    # Raised when the history cannot be read completely.
    class ReadError < StandardError; end

    # A full object name (SHA-1 or SHA-256).
    SHA = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    # A raw diff record header (`:old_mode new_mode old new status`).
    RAW = /\A\n?:[0-7]{6} [0-7]{6} [0-9a-f]+ [0-9a-f]+ [A-Z]\z/
    # A raw record with rename detection on: a rename or copy carries a
    # similarity score and two paths.
    SCORED_RAW = /\A\n?:[0-7]{6} [0-7]{6} [0-9a-f]+ [0-9a-f]+ ([A-Z])\d*\z/

    # @param root [String, Pathname] application root the walk is rooted at
    def initialize(root:)
      @root = root
    end

    # @return [String, Pathname] the application root the walk is rooted at
    attr_reader :root

    # The application's path inside its repository, as bytes ending in `/`,
    # or empty when the application is the repository root.
    #
    # @return [String] binary-encoded prefix
    # @raise [ReadError] when git cannot place the application in a repository
    def repository_prefix
      return @repository_prefix if defined?(@repository_prefix)

      prefix, _error, status = Open3.capture3(*GitCommand.argv(@root, 'rev-parse', '--show-prefix'))
      raise ReadError, 'cannot resolve application path in repository' unless status.success?

      @repository_prefix = prefix.delete_suffix("\n").b
    end

    # Run the walk and yield its binary stdout.
    #
    # @param format [String] `--format` string; must start and end each field with `%x00`
    # @param since [String] `--since` value
    # @param revision [String] the revision walked (a resolved sha keeps the walk on one HEAD)
    # @yieldparam stdout [IO]
    # @return [void]
    # @raise [ReadError] when git exits unsuccessfully
    def stream(format:, since:, revision: 'HEAD')
      argv = GitCommand.argv(@root, '-c', 'log.showSignature=false', 'log', revision,
                             "--since=#{since}", '--root', '--raw', '-z', '--no-renames',
                             '--no-relative', '--no-ext-diff', '--encoding=UTF-8',
                             '--diff-merges=first-parent', "--format=#{format}")
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        stdin.close
        stdout.binmode
        # Drain stderr without retaining a potentially unbounded diagnostic.
        drain = Thread.new { stderr.read(16_384) until stderr.eof? }
        begin
          yield stdout
          raise ReadError, "history command exited #{wait.value.exitstatus}" unless wait.value.success?
        ensure
          stdout.close
          drain.join
        end
      end
    end

    # Run a patch walk over exactly +shas+ (fed on stdin, in that order) and
    # yield its binary stdout: a NUL-led `%H` line per commit, then that
    # commit's `-U0` patch against its first parent. Paths are not quoted
    # for non-ASCII bytes (`core.quotePath=false`); see {GitLineStats}.
    #
    # @param shas [Array<String>] full commit names
    # @yieldparam stdout [IO]
    # @return [void]
    # @raise [ReadError] when git exits unsuccessfully
    def patch_stream(shas, &block)
      argv = GitCommand.argv(@root, '-c', 'log.showSignature=false', '-c', 'core.quotePath=false', 'log',
                             '--no-walk=unsorted', '--stdin', '-p', '-U0', '--no-color', '--no-renames',
                             '--no-relative', '--no-ext-diff', '--no-textconv', '--diff-merges=first-parent',
                             '--src-prefix=a/', '--dst-prefix=b/', '--encoding=UTF-8', '--format=%x00%H')
      run(argv, input: shas.map { |sha| "#{sha}\n" }.join, label: 'patch', &block)
    end

    # The renames git detects (`-M`, its default similarity) in exactly
    # +shas+, each against its first parent.
    #
    # @param shas [Array<String>] full commit names
    # @return [Hash{String => Hash{String => String}}] per commit, the new
    #   repository path (bytes) of each rename and the path it came from
    # @raise [ReadError] when git exits unsuccessfully
    def renames(shas)
      found = Hash.new { |hash, sha| hash[sha] = {} }
      return found if shas.empty?

      argv = GitCommand.argv(@root, '-c', 'log.showSignature=false', 'log', '--no-walk=unsorted', '--stdin',
                             '-M', '--raw', '-z', '--no-relative', '--no-ext-diff', '--diff-merges=first-parent',
                             '--format=%x00%H%x00')
      run(argv, input: shas.map { |sha| "#{sha}\n" }.join) { |stdout| read_renames(stdout, found) }
      found
    end

    # Read one NUL-terminated field.
    #
    # @param io [IO]
    # @return [String, nil] the field without its terminator, nil at end of stream
    # @raise [ReadError] when the stream ends inside a field
    def self.token(io)
      value = io.gets("\0")
      return nil unless value
      raise ReadError, 'unterminated history record' unless value.end_with?("\0")

      value.delete_suffix("\0")
    end

    private

    def run(argv, input: nil, label: 'history')
      Open3.popen3(*argv) do |stdin, stdout, stderr, wait|
        writer = Thread.new { stdin.write(input.to_s).then { stdin.close } }
        stdout.binmode
        drain = Thread.new { stderr.read(16_384) until stderr.eof? }
        begin
          yield stdout
          raise ReadError, "#{label} command exited #{wait.value.exitstatus}" unless wait.value.success?
        ensure
          stdout.close
          writer.join
          drain.join
        end
      end
    end

    # Calls the block with each commit name and each raw record's status and
    # paths.
    def each_record(io)
      commit = nil
      while (field = self.class.token(io))
        next if field.empty?
        next commit = field if field.match?(SHA)

        status = field[SCORED_RAW, 1]
        raise ReadError, 'unexpected history record' unless status && commit

        yield commit, status, record_paths(io, status)
      end
    end

    def record_paths(io, status)
      paths = Array.new(%w[R C].include?(status) ? 2 : 1) { self.class.token(io) }
      raise ReadError, 'incomplete path record' if paths.any?(&:nil?)

      paths
    end

    def read_renames(io, found)
      each_record(io) { |commit, status, (from, to)| found[commit][to] = from if status == 'R' }
    end
  end
end
