# frozen_string_literal: true

require_relative 'commit_table'

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
    # {PublishedIndex}, which supplies `@payload_dir`.
    module OptionalArtifacts
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
