# frozen_string_literal: true

require 'find'

module Woods
  module Watch
    # Walks a watched tree once, applying the ignore list.
    #
    # Extracted because two callers need exactly the same notion of "the files
    # under this root that could be extraction input": {PollingWatcher}, which
    # diffs two walks, and {Daemon}'s startup catch-up, which compares one walk
    # against the index's watermark. Keeping them on one implementation means
    # the daemon can never catch up over a different file set than the watcher
    # subsequently watches.
    #
    # `Find.find` with `Find.prune`, not `Dir.glob`, and the difference is
    # operational rather than stylistic. A glob enumerates the whole tree and
    # filters afterwards, so it descends into `.git` and `node_modules` and
    # stats everything inside them before discarding the results. On a monolith
    # across a virtiofs or gRPC-FUSE bind mount — the exact deployment polling
    # exists to serve — that alone can take longer than the poll interval,
    # producing sustained IO and change latency measured in tens of seconds.
    # Pruning means an ignored subtree is never entered at all.
    #
    # `Find` also takes the root as a plain path, which sidesteps the other
    # trap: a root containing glob metacharacters (`[`, `{`, `*` — all legal in
    # a directory name, and `[` shows up in generated worktree paths) makes an
    # interpolated glob pattern match nothing, silently watching an empty tree.
    module TreeScan
      # Files that look like source but are editor or VCS bookkeeping. Dotfiles
      # are skipped wholesale except where Woods genuinely reads one.
      NOT_IGNORED_DOTFILES = ['.ruby-version'].freeze

      module_function

      # Yield every watched file under a root as an absolute path.
      #
      # @param root [String, Pathname] directory to walk
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @yieldparam path [String] absolute path to a regular file
      # @return [void]
      def each_file(root:, ignored:)
        base = root.to_s
        prefix = "#{base}/"

        Find.find(base) do |path|
          next if path == base

          relative = path.delete_prefix(prefix)
          skip = skip?(relative, ignored)

          if File.directory?(path)
            Find.prune if skip
          elsif !skip
            yield path
          end
        end
      rescue Errno::ENOENT
        # The root vanished mid-walk (a worktree removed under us). Nothing to
        # report; the caller's next cycle sees it gone.
        nil
      end

      # @return [Boolean] whether this entry is neither watched nor worth
      #   descending into
      def skip?(relative, ignored)
        hidden?(relative) || ignored?(relative, ignored)
      end

      # @param root [String, Pathname] directory to walk
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @return [Array<String>] absolute paths of every watched file
      def files(root:, ignored:)
        [].tap { |paths| each_file(root: root, ignored: ignored) { |path| paths << path } }
      end

      # @param relative [String] path relative to the watched root
      # @return [Boolean] whether any segment is a dotfile Woods does not read
      def hidden?(relative)
        relative.split(File::SEPARATOR).any? do |segment|
          segment.start_with?('.') && !NOT_IGNORED_DOTFILES.include?(segment) && segment != '.' && segment != '..'
        end
      end

      # @param relative [String] path relative to the watched root
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @return [Boolean]
      def ignored?(relative, ignored)
        ignored.any? { |dir| relative == dir || relative.start_with?("#{dir}/") }
      end
    end
  end
end
