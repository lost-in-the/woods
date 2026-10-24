# frozen_string_literal: true

require_relative 'commit_table'
require_relative 'node_facts'

module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  class PublishedIndex
    # Raised when an optional payload artifact exists but cannot be read as
    # its published schema. Distinct from its absence, which readers report
    # as nil.
    class CorruptArtifactError < Woods::Error; end

    # Readers for the payload artifacts a generation may or may not publish.
    # Each answers nil when the pinned generation has none and raises
    # {CorruptArtifactError} when it has one that cannot be read. Mixed into
    # {PublishedIndex}, which supplies `@payload_dir` and `@reader`.
    module OptionalArtifacts
      # The typed units whose graph node summarises a fact (#837), read from
      # the pinned generation's graph without opening a unit:
      # `:unresolved_renders` answers `count` (entries in
      # `metadata.unresolved_renders`), `:action_facts` answers `actions` (the
      # keys of `metadata.action_facts`). Units without the fact are left out.
      #
      # @param fact [Symbol, String] `:unresolved_renders` or `:action_facts`
      # @return [Array<Hash>, nil] `{ 'identifier', 'type', 'count' | 'actions' }`,
      #   sorted; nil when the generation's writer did not summarise the fact,
      #   so a reader falls back to opening units
      # @raise [ArgumentError] for any other fact
      def units_with(fact)
        NodeFacts.call(@reader.raw_graph_data, fact)
      end

      # The pinned generation's commit table, `git_commits.json` (W-3).
      #
      # Every HEAD-reachable commit in the table's window that touched an
      # indexed path, newest first, with the files it touched, and the path
      # => commits table co-change is answered from. Read once and memoised;
      # the generation is pinned, so it never changes under this reader.
      #
      # @example Which files move with the Post model?
      #   index.git_commits&.co_changes('app/models/post.rb')
      #   # => [{ "path" => "app/controllers/posts_controller.rb", "commits" => 9 }, ...]
      #
      # @return [CommitTable, nil] nil when the generation has no table: the
      #   application had no readable git history (no `.git`, a shallow clone,
      #   an unresolvable worktree) or the index predates the table. Absence
      #   is "unknown", never "no commits".
      # @raise [CorruptArtifactError] when the file exists but is unreadable
      def git_commits
        return @git_commits if defined?(@git_commits)

        @git_commits = CommitTable.load(@payload_dir)
      end
    end
  end
end
