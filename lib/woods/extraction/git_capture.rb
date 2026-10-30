# frozen_string_literal: true

require 'open3'
require 'set'

require_relative '../git_command'
require_relative '../git_commit_table'
require_relative '../git_enrichment_summary'
require_relative '../git_history'
require_relative '../git_log'
require_relative '../git_provenance'

module Woods
  module Extraction
    # What one extraction run reads from the application's Git history.
    #
    # A run asks Git three things: whether history can be trusted at all, which
    # commit HEAD names, and the per-file facts at that commit. Each is
    # answered once per run and never re-read, so a commit landing mid-run
    # cannot relabel facts already read or move the commit table to another
    # revision. The capture also keeps the run's ledger of typed units whose
    # facts were read ({#note_refreshed}) and retained units whose facts must
    # be re-read ({#request_recheck}), which the published
    # {GitEnrichmentSummary} and incremental finalization consume.
    #
    # One instance belongs to one run. {Extractor} drops it at the start of
    # every entry point, so availability is re-probed on the next run.
    #
    # Every command is built by {GitCommand}, rooted at the application rather
    # than the process working directory.
    class GitCapture # rubocop:disable Metrics/ClassLength -- one run's probe, capture and ledger stay together
      # Unit types whose history belongs to a dependency, not the application.
      DEPENDENCY_TYPES = GitEnrichmentSummary::DEPENDENCY_TYPES

      # @return [Set<String>] identifiers of retained units whose facts this
      #   run must re-read
      attr_reader :rechecks

      # @param root [Pathname, String] application root
      # @param logger [#warn] where unavailable-history warnings go
      # @param recent_limit [Integer] recent commits kept per file
      def initialize(root:, logger:, recent_limit: GitHistory::DEFAULT_RECENT_LIMIT)
        @root = root
        @logger = logger
        @recent_limit = recent_limit
        @availability = nil
        @head = nil
        @branch = GitProvenance::UNKNOWN
        @head_resolved = false
        @history_failed = false
        @history_reason = nil
        @refreshed = Set.new
        @rechecks = Set.new
      end

      # Can this run's git calls produce real facts?
      #
      # `rev-parse --git-dir` alone is not enough. Over a linked worktree whose
      # private git directory is reachable but whose `commondir` is not, it
      # answers while every ref lookup fails and `git log` exits 0 with nothing
      # to say. Enrichment then wrote `commit_count: 0` and
      # `change_frequency: new` onto every unit, which reads exactly like a file
      # that was never committed, where an absent git directory correctly omits
      # the keys (B-186). HEAD has to resolve, with complete ancestry (B-189).
      #
      # Probed once, so its warning is emitted at most once per run.
      #
      # @return [Boolean]
      def available?
        availability.fetch(:available)
      end

      # Whether this run's git calls can produce facts, and when they cannot, a
      # stable reason for the published {GitEnrichmentSummary}.
      #
      # @return [Hash] `{available: Boolean, reason: String, nil}`
      def availability
        @availability ||= probe_availability
      end

      # The commit this run reads, resolved on first use. Later commits must
      # not relabel already-read facts, or put the commit table on a different
      # revision. A failed resolution stays failed for the rest of the run.
      #
      # @return [String, nil] full commit SHA, without environment fallback
      def head
        return @head if @head_resolved

        @head_resolved = true
        # Resolve the named ref itself, so a checkout between these commands
        # cannot pair the old branch name with the new branch's commit.
        ref = run_git('symbolic-ref', '--quiet', 'HEAD')
        revision = ref.empty? ? 'HEAD' : ref
        sha = run_git('rev-parse', '--verify', "#{revision}^{commit}")
        return unless sha.match?(GitLog::SHA)

        @branch = ref.start_with?('refs/heads/') ? ref.delete_prefix('refs/heads/') : GitProvenance::UNKNOWN
        @head = sha
      end

      # Manifest provenance for the commit this run already read. Never
      # resolves HEAD itself: a run that read no history has no capture, and
      # the caller falls back to {GitProvenance}.
      #
      # @return [Hash, nil] `{git_sha:, git_branch:}`, nil without a capture
      def provenance
        { git_sha: @head, git_branch: @branch } if @head
      end

      # Per-file facts at the captured HEAD, from one history walk
      # independent of requested-path grouping. See {GitHistory} for merge
      # semantics and binary record framing. A HEAD that cannot be resolved,
      # or a walk that fails, yields no facts and marks this run's history
      # unreadable in the published summary.
      #
      # @param file_paths [Array<String>] absolute file paths
      # @return [Hash{String => Hash}] keyed by root-relative path
      def file_facts(file_paths)
        return {} if file_paths.empty?

        sha = head
        return history_failed! unless sha

        recent_after = Time.current - 90.days
        raw = GitHistory.new(root: @root, logger: @logger, recent_limit: @recent_limit)
                        .read(file_paths.map { |path| relative(path) }.uniq, recent_after: recent_after, revision: sha)
        return history_failed! unless raw

        raw.transform_values { |data| file_metadata(data, recent_after.iso8601) }
      end

      # The `git_commits.json` table (W-3) this run publishes, nil for none.
      #
      # The table is a pure function of HEAD, the indexed path set and the
      # bounds ({GitCommitTable}). A full run always walks; an incremental run
      # keeps the seeded table when it records the same inputs, so both modes
      # publish the same bytes. Without a readable history there is no table.
      #
      # @param published [Hash, nil] the table the payload was seeded with
      # @param graph [DependencyGraph] the run's final graph
      # @param full [Boolean] whether this is a full extraction
      # @return [Hash, nil]
      def commit_table(published, graph:, full:)
        return nil unless available?

        sha = head
        return nil unless sha

        paths = commit_table_paths(graph)
        builder = GitCommitTable.new(root: @root, logger: @logger, settings: GitCommitTable.settings)
        return published if !full && GitCommitTable.current?(published, builder.key(paths, head: sha))

        builder.build(paths, head: sha)
      end

      # The published account of whether this generation's Git facts can be
      # trusted. Counts come from the graph, so no unit is read; a failed
      # history read after a resolvable HEAD still counts as unavailable.
      #
      # @param graph [DependencyGraph] the publication's final graph
      # @param full [Boolean] true when every unit's facts were read this run
      # @return [Hash]
      def enrichment_summary(graph:, full:)
        state = availability
        state = { available: false, reason: 'history_read_failed' } if state[:available] && @history_failed
        sha = state[:available] ? head : nil

        GitEnrichmentSummary.build(graph: graph, root: @root.to_s, availability: state,
                                   refreshed: full ? :all : @refreshed,
                                   head_sha: sha&.match?(GitLog::SHA) ? sha : nil)
      end

      # Facts for this typed unit were read in this publication, as opposed to
      # carried over from an earlier capture.
      #
      # @param identifier [String]
      # @param type [Symbol, String]
      # @return [void]
      def note_refreshed(identifier, type)
        @refreshed.add([identifier, type.to_s])
      end

      # A retained unit's sources changed, so its facts must be read again.
      #
      # @param identifier [String]
      # @return [void]
      def request_recheck(identifier)
        @rechecks.add(identifier)
      end

      private

      # @return [Hash] see {#availability}
      def probe_availability
        _output, error, status = Open3.capture3(*git_argv('rev-parse', 'HEAD'))
        unless status.success?
          warn_unresolvable(error)
          return { available: false, reason: requested? ? 'head_unresolvable' : 'no_repository' }
        end

        complete_history? ? { available: true, reason: nil } : { available: false, reason: @history_reason }
      rescue Errno::ENOENT
        warn_missing_executable
        { available: false, reason: 'git_executable_missing' }
      rescue StandardError
        { available: false, reason: 'git_error' }
      end

      # @return [Hash] no facts, after recording that history was unreadable
      def history_failed!
        @history_failed = true
        {}
      end

      # A working tree or an explicit Git directory asks for history. Without
      # either, an unresolvable HEAD is an ordinary source archive.
      #
      # @return [Boolean]
      def requested?
        [GitCommand::OVERRIDE_KEY, 'GIT_DIR'].any? { |key| !ENV[key].to_s.empty? } ||
          File.exist?(File.join(@root.to_s, '.git'))
      end

      # An explicit Git directory still requests history when .git is not mounted
      # at the root. Ordinary source archives remain a supported, quiet path.
      #
      # @return [void]
      def warn_missing_executable
        return unless requested?

        @logger.warn(
          '[Woods] Git history unavailable: git executable was not found in PATH. ' \
          'Extraction continues without per-unit Git metadata. Install Git in the extraction environment ' \
          'and run a full extraction to refresh Git metadata.'
        )
      end

      # A shallow HEAD resolves but represents an incomplete ancestry. Do not
      # turn that boundary into apparent one-commit/new-file churn facts.
      #
      # @return [Boolean]
      def complete_history?
        output, _error, status = Open3.capture3(*git_argv('rev-parse', '--is-shallow-repository'))
        return true if status.success? && output.strip == 'false'

        shallow = status.success? && output.strip == 'true'
        reason = shallow ? 'shallow repository' : 'repository depth could not be verified'
        @history_reason = shallow ? 'shallow_repository' : 'depth_unverifiable'
        @logger.warn(
          "[Woods] Git enrichment omitted: #{reason}. Fetch full history with git fetch --unshallow " \
          '(or actions/checkout fetch-depth: 0), then run full extraction to refresh git metadata.'
        )
        false
      end

      # Say once why no unit will carry git metadata, but only when there is a
      # working tree to explain. No `.git` at the root is the ordinary source
      # tarball or `COPY`-without-`.git` case, and it is not a fault.
      #
      # @param error [String] git's own stderr
      # @return [void]
      def warn_unresolvable(error)
        return unless File.exist?(File.join(@root.to_s, '.git'))

        cause = error.to_s.lines.first.to_s.strip
        @logger.warn(
          '[Woods] git cannot resolve HEAD for this working tree, so no unit will carry git ' \
          "metadata: #{cause}. For a linked worktree, mount the complete shared .git directory " \
          'at its original path, or set WOODS_GIT_DIR to /mounted-common/worktrees/<id> within ' \
          'the relocated complete layout. Derive <id> from the worktree Git metadata, not its branch name; ' \
          "selecting /mounted-common itself uses the primary checkout's HEAD."
        )
      end

      # `-C <root>` keeps the result independent of the process working
      # directory. `WOODS_GIT_DIR` wins when set and selects that git
      # directory's HEAD (B-181).
      #
      # @param args [Array<String>] git arguments
      # @return [Array<String>] full argv
      def git_argv(*args)
        GitCommand.argv(@root, *args)
      end

      # Safe git command execution — no shell interpolation.
      #
      # @param args [Array<String>] Git command arguments
      # @return [String] command output (empty string on failure)
      def run_git(*args)
        output, _error, status = Open3.capture3(*git_argv(*args))
        status.success? ? output.strip : ''
      rescue StandardError
        ''
      end

      # Application-owned paths of every indexed unit, by the rule per-unit
      # enrichment uses ({GitEnrichmentSummary.enrichable_path?}), read off the
      # final graph so full and incremental runs see one set.
      #
      # @param graph [DependencyGraph]
      # @return [Array<String>] sorted root-relative paths
      def commit_table_paths(graph)
        prefix = "#{@root}/"
        graph.registered_paths.filter_map do |registered|
          path = File.expand_path(registered.to_s, @root.to_s)
          next unless GitEnrichmentSummary.enrichable_path?(path, prefix)
          next if graph.units_for_path(registered).all? { |_, type| DEPENDENCY_TYPES.include?(type) }

          relative(path)
        end.uniq.sort
      end

      # @param path [String]
      # @return [String] root-relative when under the root, else unchanged
      def relative(path)
        root = @root.to_s
        prefix = root.end_with?('/') ? root : "#{root}/"
        path.start_with?(prefix) ? path.delete_prefix(prefix) : path
      end

      # Published metadata from one file's raw commit data.
      #
      # @param data [Hash] one {GitHistory#read} entry
      # @param recent_after [String] ISO 8601 start of the recent window
      # @return [Hash]
      def file_metadata(data, recent_after)
        commits = data[:commits] || []
        recent_count = data.fetch(:recent_count) { commits.count { |c| c[:date] && c[:date] > recent_after } }
        total_count = data.fetch(:commit_count, commits.size)

        {
          last_modified: data[:last_modified],
          last_author: data[:last_author],
          commit_count: total_count,
          contributors: top_contributors(data[:contributors] || {}),
          recent_commits: commits.first(@recent_limit).map { |commit| recent_commit(commit) },
          change_frequency: change_frequency(total_count, recent_count)
        }
      end

      # @param counts [Hash{String => Integer}] commits by author
      # @return [Array<Hash>] the five most active authors
      def top_contributors(counts)
        counts.sort_by { |_, count| -count }.first(5).map { |name, count| { name: name, commits: count } }
      end

      # @param commit [Hash] one raw commit
      # @return [Hash] its published form, with an abbreviated SHA
      def recent_commit(commit)
        { sha: commit[:sha]&.first(8), message: commit[:message], date: commit[:date], author: commit[:author] }
      end

      # @return [Symbol] how often a file changes, from its commit counts
      def change_frequency(total_count, recent_count)
        if total_count <= 2
          :new
        elsif recent_count >= 10
          :hot
        elsif recent_count >= 3
          :active
        elsif recent_count >= 1
          :stable
        else
          :dormant
        end
      end
    end
  end
end
