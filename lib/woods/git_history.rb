# frozen_string_literal: true

require 'time'
require_relative 'git_log'

module Woods
  # Stream HEAD-reachable touched-path events without pathspec simplification.
  # Raw NUL records keep filenames separate from commit fields; only requested
  # paths are retained. Merge diffs compare against the first parent, while
  # traversal still visits every parent. Requires Git 2.31 or newer. The walk
  # itself is {GitLog}, shared with {GitCommitTable}.
  class GitHistory
    ReadError = GitLog::ReadError

    # How many commit records each path keeps when no limit is given; the
    # per-unit `recent_commits` default (`config.git_recent_commits`).
    DEFAULT_RECENT_LIMIT = 5

    FORMAT = '%x00%H%x00%an%x00%cI%x00%s%x00'
    private_constant :FORMAT

    # @param root [String, Pathname] application root
    # @param logger [#warn]
    # @param recent_limit [Integer] commit records retained per path
    def initialize(root:, logger:, recent_limit: DEFAULT_RECENT_LIMIT)
      @log = GitLog.new(root: root)
      @logger = logger
      @recent_limit = recent_limit
    end

    # @param revision [String] commit to walk; a resolved SHA pins the capture
    # @return [Hash, nil] raw per-path aggregates, or nil on any incomplete read
    def read(paths, recent_after:, revision: 'HEAD')
      requested = paths.to_h { |path| [@log.repository_prefix + path.b, path] }
      result = paths.to_h { |path| [path, {}] }
      @log.stream(format: FORMAT, since: '365 days ago', revision: revision) do |stdout|
        parse(stdout, requested, result, recent_after)
      end
      result
    rescue StandardError => e
      @logger.warn('[Woods] Git enrichment omitted: history could not be read completely. ' \
                   'Git 2.31 or newer is required; check the application repository and git installation. ' \
                   "(#{e.class})")
      nil
    end

    private

    def token(io)
      GitLog.token(io)
    end

    def parse(io, requested, result, recent_after)
      commit = nil
      while (field = token(io))
        next if field.empty?

        if field.match?(GitLog::SHA)
          commit = read_commit(io, field, recent_after)
        elsif field.match?(GitLog::RAW)
          record_path(io, requested, result, commit)
        else
          raise ReadError, 'unexpected history record'
        end
      end
    end

    def read_commit(io, sha, recent_after)
      author, date, message = Array.new(3) { token(io) }
      raise ReadError, 'incomplete commit header' unless author && date && message

      { sha: sha, author: author.force_encoding(Encoding::UTF_8),
        date: date, message: message.force_encoding(Encoding::UTF_8), recent: Time.iso8601(date) > recent_after }
    end

    def record_path(io, requested, result, commit)
      path = token(io)
      raise ReadError, 'incomplete path record' unless commit && path

      relative = requested[path]
      record(result[relative], commit) if relative
    end

    def record(data, commit)
      data[:last_modified] ||= commit[:date]
      data[:last_author] ||= commit[:author]
      data[:commit_count] = data.fetch(:commit_count, 0) + 1
      data[:recent_count] = data.fetch(:recent_count, 0) + (commit[:recent] ? 1 : 0)
      commits = (data[:commits] ||= [])
      commits << commit if commits.size < @recent_limit
      (data[:contributors] ||= Hash.new(0))[commit[:author]] += 1
    end
  end
end
