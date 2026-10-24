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

    # @param root [String, Pathname] application root the walk is rooted at
    def initialize(root:)
      @root = root
    end

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
  end
end
