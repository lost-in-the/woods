# frozen_string_literal: true

require 'set'
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
    # Renames followed back from one file before its `added` mark is kept.
    RENAME_DEPTH = 8
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
      @walk = { order: {}, deleting: Set.new, adds: {}, created: Hash.new { |hash, path| hash[path] = [] } }
      @log.stream(format: FORMAT, since: '365 days ago', revision: revision) do |stdout|
        parse(stdout, requested, result, recent_after)
      end
      unmark_renamed(result)
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
          @walk[:deleting] << commit[:sha] if commit && field.end_with?('D')
          record_path(io, requested, result, commit, added: field.end_with?('A'))
        else
          raise ReadError, 'unexpected history record'
        end
      end
    end

    def read_commit(io, sha, recent_after)
      author, date, message = Array.new(3) { token(io) }
      raise ReadError, 'incomplete commit header' unless author && date && message

      @walk[:order][sha] = @walk[:order].size

      { sha: sha, author: author.force_encoding(Encoding::UTF_8),
        date: date, message: message.force_encoding(Encoding::UTF_8), recent: Time.iso8601(date) > recent_after }
    end

    def record_path(io, requested, result, commit, added:)
      path = token(io)
      raise ReadError, 'incomplete path record' unless commit && path

      # Every creation in the window, by repository path: where a renamed
      # file's source came from (see #unmark_renamed).
      @walk[:created][path] << commit[:sha] if added
      relative = requested[path]
      return unless relative

      record(result[relative], commit)
      # The commit that created the file is inside the window: the file is
      # new, not merely quiet. Without it, a file with few commits in the
      # window is indistinguishable from one written years ago.
      return unless added

      result[relative][:added] = true
      @walk[:adds][relative] ||= [commit[:sha], path] # the newest creation
    end

    # `added` means the file's content first appeared inside the window. The
    # walk reads history without rename detection, so a file renamed into
    # place reads as added. Only a creating commit that also deletes a path
    # can be a rename: those commits are read again with rename detection,
    # and a rename is followed to the commit that added its source, if the
    # window holds one. A source older than the window unmarks the file.
    def unmark_renamed(result)
      pending = @walk[:adds].select { |_relative, (sha, _path)| @walk[:deleting].include?(sha) }
      RENAME_DEPTH.times do
        break if pending.empty?

        pending = follow_renames(pending, result)
      end
    end

    # One step back along each pending file's renames.
    #
    # @return [Hash] the files whose source was itself created by a commit
    #   that may be a rename
    def follow_renames(pending, result)
      renames = @log.renames(pending.values.map(&:first).uniq)
      sources = pending.filter_map do |relative, (sha, path)|
        source = renames[sha][path]
        [relative, sha, source] if source
      end
      sources.each_with_object({}) do |(relative, sha, source), following|
        older = creation_before(source, sha)
        if older.nil? then result[relative].delete(:added)
        elsif @walk[:deleting].include?(older) then following[relative] = [older, source]
        end
      end
    end

    # @return [String, nil] the newest commit older than +sha+ that created
    #   +path+, inside the window
    def creation_before(path, sha)
      position = @walk[:order].fetch(sha)
      @walk[:created].fetch(path, []).find { |candidate| @walk[:order].fetch(candidate, -1) > position }
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
