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

    FORMAT = '%x00%H%x00%P%x00%an%x00%cI%x00%s%x00'
    # Renames and merges followed back from one file before its `added` mark
    # is kept.
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
      @walk = { parents: {}, deleting: Set.new, created: Hash.new { |hash, path| hash[path] = [] } }
      @log.stream(format: FORMAT, since: '365 days ago', revision: revision) do |stdout|
        parse(stdout, requested, result, recent_after)
      end
      unmark_renamed(result, requested)
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
      parents, author, date, message = Array.new(4) { token(io) }
      raise ReadError, 'incomplete commit header' unless parents && author && date && message

      @walk[:parents][sha] = parents.split

      { sha: sha, author: author.force_encoding(Encoding::UTF_8),
        date: date, message: message.force_encoding(Encoding::UTF_8), recent: Time.iso8601(date) > recent_after }
    end

    def record_path(io, requested, result, commit, added:)
      path = token(io)
      raise ReadError, 'incomplete path record' unless commit && path

      # Every creation in the window, by repository path: where a file and a
      # renamed file's source came from (see #unmark_renamed).
      @walk[:created][path] << commit[:sha] if added
      relative = requested[path]
      return unless relative

      record(result[relative], commit)
      # The commit that created the file is inside the window: the file is
      # new, not merely quiet. Without it, a file with few commits in the
      # window is indistinguishable from one written years ago.
      result[relative][:added] = true if added
    end

    # `added` means the file's content first appeared inside the window. Each
    # commit's diff is against its first parent, so a file's creation is the
    # newest commit on HEAD's first-parent chain that adds it. The walk reads
    # history without rename detection, so that commit may have brought older
    # content instead: a commit that also deletes a path may be a rename, and
    # a merge adds what another parent held. Both are followed back, each in
    # the history that reaches it; content older than the window unmarks the
    # file. Walk order is not ancestry and decides nothing here.
    def unmark_renamed(result, requested)
      head = @walk[:parents].each_key.first # git prints the walked revision first
      pending = requested.each_with_object({}) do |(path, relative), found|
        step(result, relative, creation_on_chain(path, [head]), path, found) if result[relative][:added]
      end
      RENAME_DEPTH.times do
        break if pending.empty?

        pending = follow_back(pending, result)
      end
    end

    # One step back from each pending file's creation: to a rename's source
    # in the rename's first parent, or to a merged file in the merge's other
    # parents.
    #
    # @return [Hash] the files whose earlier creation may itself be inherited
    def follow_back(pending, result)
      renames = @log.renames(pending.values.map(&:first).select { |sha| @walk[:deleting].include?(sha) }.uniq)
      pending.each_with_object({}) do |(relative, (sha, path)), following|
        if (source = renames[sha][path])
          step(result, relative, creation_on_chain(source, @walk[:parents].fetch(sha).first(1)), source, following)
        # Only a rename's source is known to exist in its parent. A merge whose
        # other parents add the file nowhere may have made it itself, and a
        # commit with one parent did: both keep the mark.
        elsif (creation = creation_on_chain(path, @walk[:parents].fetch(sha).drop(1)))
          step(result, relative, creation, path, following)
        end
      end
    end

    def step(result, relative, creation, path, following)
      return result[relative].delete(:added) if creation.nil?

      following[relative] = [creation, path] if inherited?(creation)
    end

    def inherited?(sha)
      @walk[:deleting].include?(sha) || @walk[:parents].fetch(sha).size > 1
    end

    # @return [String, nil] the newest commit inside the window that adds
    #   +path+ on the first-parent chain of one of +heads+ (the head included)
    def creation_on_chain(path, heads)
      candidates = @walk[:created].fetch(path, nil)
      candidates && (@walk[:chains] ||= Chains.new(@walk[:parents])).newest(candidates, heads)
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

    # The first-parent chains of the walked commits, as entry and exit times
    # of one depth-first pass over their first-parent forest. A commit is on
    # another's first-parent chain exactly when its span encloses the
    # other's, and the nearer of two such commits entered later, so no chain
    # is walked per lookup. A first parent outside the walk (older than the
    # window, or cut off by a shallow clone or a graft) ends its chain.
    class Chains
      # @param parents [Hash{String => Array<String>}] each walked commit's parents
      def initialize(parents)
        children = Hash.new { |hash, sha| hash[sha] = [] }
        roots = []
        parents.each { |sha, (first, *)| (parents.key?(first) ? children[first] : roots) << sha }
        @spans = spans(roots, children)
      end

      # @param candidates [Array<String>] walked commits
      # @param heads [Array<String>] tried in order
      # @return [String, nil] the candidate nearest the first head whose
      #   first-parent chain (the head included) holds one
      def newest(candidates, heads)
        heads.each do |head|
          next unless (span = @spans[head])

          on_chain = candidates.select { |sha| encloses?(@spans.fetch(sha), span) }
          return on_chain.max_by { |sha| @spans.fetch(sha).first } if on_chain.any?
        end
        nil
      end

      private

      def encloses?(outer, inner)
        outer.first <= inner.first && inner.last <= outer.last
      end

      def spans(stack, children)
        spans = {}
        clock = 0
        until stack.empty?
          sha = stack.last
          if spans.key?(sha)
            spans[sha][1] = (clock += 1)
            stack.pop
          else
            spans[sha] = [clock += 1, nil]
            stack.concat(children.fetch(sha, []))
          end
        end
        spans
      end
    end
    private_constant :Chains
  end
end
