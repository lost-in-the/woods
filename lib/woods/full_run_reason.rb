# frozen_string_literal: true

module Woods
  # Why `woods:incremental` ran a full extraction instead (#948).
  #
  # A restart input (a dependency manifest, an initializer, the schema dump)
  # changes state captured at boot, so the one-shot task runs `extract_all` for
  # it. The task used to print only "Full extraction for N changed files",
  # which left two things unsaid: which of those paths forced the full run,
  # and where each came from. The second matters because the default range is
  # `git diff HEAD~1`, a single revision diffed against the working tree: an
  # uncommitted local Gemfile pin forces a full run as surely as a committed
  # one, and nothing said so.
  #
  # The source of each forcing path is answered with two more diffs, run only
  # when a full run is already decided: `<rev>..HEAD` (committed) and `HEAD`
  # (working tree, staged or not). A two-revision range (`a..b`, `a...b`) never
  # reads the working tree, so every path in it is committed. Paths named by
  # `CHANGED_FILES` never touched git.
  class FullRunReason
    # Forcing paths listed before the rest are only counted.
    LIMIT = 10

    # @param paths [Array<String>] application-relative paths that forced the run
    # @param range [String, nil] the git range the change set came from, or nil
    #   when `CHANGED_FILES` named it
    # @param diff [#call] `diff.call(range)` returns `[paths, failure]`, the
    #   shape of {RakeHelpers.woods_changed_paths_for_range}
    def initialize(paths:, range:, diff:)
      @paths = Array(paths)
      @range = range
      @diff = diff
    end

    # @return [Array<String>] printable lines; empty when nothing forced the run
    def lines
      return [] if @paths.empty?

      sources = @paths.first(LIMIT).to_h { |path| [path, source_of(path)] }
      rows = sources.map { |path, source| "  - #{path} (#{source})" }
      rows << "  ... and #{@paths.size - LIMIT} more" if @paths.size > LIMIT
      [header, *rows, *working_tree_note]
    end

    private

    def header
      count = @paths.size
      noun = count == 1 ? 'restart input' : 'restart inputs'
      "Full extraction forced by #{count} #{noun} (state captured at boot, which an incremental run cannot refresh):"
    end

    # Judged over every forcing path, listed or not; the diffs are memoized.
    def working_tree_note
      return [] unless @paths.any? { |path| source_of(path).include?('working tree') }

      ["Uncommitted changes are included: with no CHANGED_FILES or CI range, the change set is `git diff #{@range}` " \
       'against the working tree (staged and unstaged; untracked files are not). Commit, stash or revert them, ' \
       'or set CHANGED_FILES, to leave them out.']
    end

    def source_of(path)
      return 'named by CHANGED_FILES' if @range.nil?
      return "committed in #{@range}" if two_revision_range?

      single_revision_source(path)
    end

    # A single revision diffs against the working tree, so the path may come
    # from the commits after it, from uncommitted work, or both. A diff that
    # fails attributes nothing, which leaves the source unknown, never guessed.
    def single_revision_source(path)
      committed = committed_paths.include?(path)
      worktree = working_tree_paths.include?(path)
      return "committed in #{committed_range}, then changed again in the working tree" if committed && worktree
      return "committed in #{committed_range}" if committed
      return 'working tree, uncommitted' if worktree

      'source unknown: git could not attribute it'
    end

    def two_revision_range?
      @range.include?('..')
    end

    def committed_range
      "#{@range}..HEAD"
    end

    def committed_paths
      @committed_paths ||= paths_for(committed_range)
    end

    def working_tree_paths
      @working_tree_paths ||= paths_for('HEAD')
    end

    def paths_for(range)
      paths, failure = @diff.call(range)
      failure ? [] : Array(paths)
    end
  end
end
