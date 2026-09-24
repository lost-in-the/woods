# frozen_string_literal: true

require 'find'
require 'set'
require 'woods/source_path_encoding'

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

      # Dotfile *prefixes* Woods still has to see. `.env`, `.env.local`,
      # `.env.development` and friends are boot-captured configuration
      # ({ReloadPolicy} classifies them `:restart`), so filtering them out here
      # would make that classification unreachable — the daemon would never
      # learn the file changed at all.
      NOT_IGNORED_DOTFILE_PREFIXES = ['.env'].freeze

      module_function

      # Yield every watched file under a root as an absolute path.
      #
      # @param root [String, Pathname] directory to walk
      # @param ignored [Array<String>] directory names/prefixes to skip
      # @yieldparam path [String] absolute path to a regular file
      # @return [void]
      def each_file(root:, ignored:, visited: nil, &block)
        base = SourcePathEncoding.utf8(root)
        return unless base

        prefix = "#{base}/"
        visited = (visited || Set.new).dup
        visited << real_dir(base)

        Find.find(base) do |path|
          path = decoded_entry(path)
          next if path == base

          skip = skip?(path.delete_prefix(prefix), ignored)
          Find.prune if visit_entry(path, skip, ignored, visited, root: base, &block) == :prune
        end
      rescue Errno::ENOENT
        # The root vanished mid-walk (a worktree removed under us). Nothing to
        # report; the caller's next cycle sees it gone.
        nil
      end

      # Prune before any string matching or descent into an undecodable entry.
      def decoded_entry(path)
        SourcePathEncoding.utf8(path) || Find.prune
      end

      # Classify one entry and act on it.
      #
      # @return [Symbol, nil] `:prune` when the caller should not descend
      def visit_entry(path, skip, ignored, visited, root:, &block)
        # `Find` stats with `lstat`, so it neither descends a symlinked
        # directory nor reports one as a file — the entry would just vanish. A
        # full extraction globs, and `Dir.glob` *does* follow them, so leaving
        # this alone meant the daemon was blind to a tree the oracle indexes: a
        # symlinked `app/models`, or a monorepo linking shared code in, simply
        # never produced an event.
        if symlinked_directory?(path)
          descend_symlink(path, ignored, visited | directory_ancestors(path, root), &block) unless skip
          nil
        elsif File.directory?(path)
          skip ? :prune : nil
        else
          block.call(path) unless skip
          nil
        end
      end

      # Detect cycles along this logical traversal branch, not across siblings.
      # Two aliases of one target are distinct extraction paths: suppressing
      # one can leave only an ignored alias and hide the relevant app path.
      # Find does not expose exit events for ordinary directories, so collect
      # their ancestors at each symlink rather than retaining a global set.
      def directory_ancestors(path, root)
        ancestors = Set.new
        directory = File.dirname(path)
        loop do
          ancestors << real_dir(directory)
          break if directory == root || File.dirname(directory) == directory

          directory = File.dirname(directory)
        end
        ancestors
      end

      def descend_symlink(path, ignored, visited, &block)
        target = real_dir(path)
        return if target.nil? || visited.include?(target)

        # Walk the *resolved* directory — `Find.find` lstats even the root it is
        # handed, so pointing it at the link itself yields the link and stops —
        # then rewrite each result back under the link. Callers compare these
        # paths against change sets and the graph's registered paths, so they
        # have to read as the tree looks, not as it resolves.
        each_file(root: target, ignored: ignored, visited: visited) do |file|
          block.call(File.join(path, file.delete_prefix("#{target}/")))
        end
      end

      # @return [Boolean] true for a symlink that resolves to a directory
      def symlinked_directory?(path)
        File.symlink?(path) && File.directory?(path)
      rescue SystemCallError
        false
      end

      # @return [String, nil] resolved path, or nil for a broken/looping link
      def real_dir(path)
        SourcePathEncoding.utf8(File.realpath(path))
      rescue SystemCallError
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
        relative = SourcePathEncoding.utf8(relative)
        return true unless relative

        relative.split(File::SEPARATOR).any? { |segment| hidden_segment?(segment) }
      end

      # @param segment [String] one path component
      # @return [Boolean]
      def hidden_segment?(segment)
        return false unless segment.start_with?('.')
        return false if ['.', '..'].include?(segment)
        return false if NOT_IGNORED_DOTFILES.include?(segment)

        NOT_IGNORED_DOTFILE_PREFIXES.none? { |prefix| segment.start_with?(prefix) }
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
