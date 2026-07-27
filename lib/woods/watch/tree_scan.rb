# frozen_string_literal: true

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
    # Note `base:` rather than interpolating the root into the pattern: a root
    # containing glob metacharacters (`[`, `{`, `*` — all legal in a directory
    # name, and `[` in particular shows up in generated worktree paths) makes an
    # interpolated pattern match nothing at all, silently watching an empty
    # tree.
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

        Dir.glob('**/*', File::FNM_DOTMATCH, base: base).each do |relative|
          next if hidden?(relative)
          next if ignored?(relative, ignored)

          absolute = File.join(base, relative)
          next unless File.file?(absolute)

          yield absolute
        end
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
