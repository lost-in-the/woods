# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'
require_relative '../source_file'
require_relative '../git_source_filter'
require_relative 'config_file_extractor'
require_relative '../markdown/line_scan'
require_relative '../chunking/markdown_section_chunker'
require_relative '../watch/tree_scan'
require_relative '../watch/watcher'
require_relative 'doc_mentions'

module Woods
  module Extractors
    # DocExtractor indexes project documentation as `doc` units, one per
    # Markdown file under `Woods.configuration.documentation_paths`.
    #
    # A unit's identifier is its root-relative path. Its source is the file
    # with credential shapes redacted ({DocRedaction}); its metadata holds the
    # title, heading outline, front matter, links and the code mentions that
    # may name an indexed unit. Dependencies start empty: whether a mention or
    # a link names a unit depends on the whole index, so
    # {Woods::DocReferences} resolves them after every extractor has run.
    #
    # A secret-named file ({ConfigFileExtractor.secret_path?}) is never read,
    # nor is one a symlink reaches outside the documentation roots. In a Git
    # checkout, ignored and untracked files are skipped like other
    # configuration sources.
    #
    # Reads bytes only. No constant is loaded and no Rails API is called.
    #
    # @example
    #   unit = DocExtractor.new.extract_doc_file(Rails.root.join('docs/setup.md').to_s)
    #   unit.identifier               # => "docs/setup.md"
    #   unit.metadata[:title]         # => "Setup"
    #   unit.metadata[:mentions]      # => [{ kind: "constant", text: "Widget", line: 4, resolved: false }]
    class DocExtractor
      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      # The default roots as plain data: the dispatch rule hands them to the
      # generated hook predicate, which runs without a configuration.
      DEFAULT_ROOT_FILES = %w[README.md CLAUDE.md AGENTS.md].freeze
      DEFAULT_ROOT_DIRECTORIES = %w[docs doc .claude/rules .claude/skills .github].freeze
      # A larger file is generated output, not documentation someone reads.
      MAX_DOC_BYTES = 1_048_576
      # Unique mention candidates kept per document, in order of appearance.
      MAX_MENTIONS = 500
      URL_SCHEME = %r{\A(?:[A-Za-z][A-Za-z0-9+.-]*+:|//)}
      PERCENT_ESCAPE = /%([0-9A-Fa-f]{2})/
      BEFORE_FRAGMENT = /\A[^#?]*+/
      private_constant :URL_SCHEME, :PERCENT_ESCAPE, :BEFORE_FRAGMENT

      class << self
        # Is this a documentation file the extractor indexes?
        #
        # Reads the configured globs at call time. A path the source capture
        # and the watch daemon never read (hidden, or under an ignored
        # directory) is never a documentation path, whatever the globs say.
        #
        # @param relative_path [String] Rails.root-relative path
        # @return [Boolean]
        def doc_path?(relative_path)
          return false if Watch::TreeScan.hidden?(relative_path) ||
                          Watch::TreeScan.ignored?(relative_path, Watch::Watcher::DEFAULT_IGNORED_DIRECTORIES)

          matches?(documentation_paths, relative_path) && !matches?(documentation_exclude, relative_path) &&
            !ConfigFileExtractor.secret_path?(relative_path)
        end

        # @return [Array<String>] configured root-relative globs
        def documentation_paths
          Woods.configuration&.documentation_paths || Woods::Configuration::DEFAULT_DOCUMENTATION_PATHS
        end

        # @return [Array<String>] configured root-relative exclusion globs
        def documentation_exclude
          Woods.configuration&.documentation_exclude || Woods::Configuration::DEFAULT_DOCUMENTATION_EXCLUDE
        end

        private

        def matches?(globs, relative_path)
          globs.any? { |glob| File.fnmatch?(glob, relative_path, GLOB_FLAGS) }
        end
      end

      def initialize
        # Loaded here, not at require time: the dispatch rules and the reload
        # policy name this class without ever scanning a document.
        require_relative 'doc_redaction'
        @root = Rails.root.to_s
        @real_root = File.realpath(@root)
        @redaction = DocRedaction.new
      end

      # Extract every documentation file under the configured paths.
      #
      # @return [Array<ExtractedUnit>] `doc` units, sorted by identifier
      def extract_all
        paths = candidate_paths
        index = alias_index(paths)
        aliased = index.values.flatten.to_set
        paths.reject { |relative| aliased.include?(relative) }
             .filter_map { |relative| extract_doc_file(File.join(@root, relative), aliases: index) }
      end

      # Extract one documentation file.
      #
      # A path that reaches another indexed document through a symlink is an
      # alias: it yields that document's unit, which lists every alias in
      # `metadata[:aliases]`. One text is one unit, whichever path names it.
      #
      # @param file_path [String] absolute path to a Markdown file
      # @param aliases [Hash, nil] a precomputed {#alias_index}
      # @return [ExtractedUnit, nil] the unit, or nil when the path is not a
      #   documentation file, is over {MAX_DOC_BYTES}, or cannot be read
      def extract_doc_file(file_path, aliases: nil)
        relative = file_path.to_s.delete_prefix("#{@root}/")
        return nil unless self.class.doc_path?(relative) && File.file?(file_path)

        target = documentation_target(file_path)
        return nil unless target && readable?(relative, target)

        identity = target.delete_prefix("#{@real_root}/")
        return extract_doc_file(File.join(@root, identity), aliases: aliases) unless identity == relative
        return skip_oversize(relative) if File.size(target) > MAX_DOC_BYTES

        alias_paths = Array((aliases || alias_index(candidate_paths))[target])
                      .select { |path| readable?(path, target) }
        build_unit(relative, file_path, SourceFile.read(target), alias_paths)
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract documentation #{file_path}: #{e.message}")
        nil
      end

      private

      # @return [Array<String>] sorted root-relative paths the configured globs match
      def candidate_paths
        self.class.documentation_paths
            .flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }
            .uniq.sort
      end

      # @param paths [Array<String>] root-relative candidate paths
      # @return [Hash{String => Array<String>}] resolved document path => the
      #   sorted candidate paths that reach it through a symlink
      def alias_index(paths)
        paths.each_with_object({}) do |relative, index|
          next unless self.class.doc_path?(relative)

          target = documentation_target(File.join(@root, relative))
          next if target.nil? || target.delete_prefix("#{@real_root}/") == relative

          (index[target] ||= []) << relative
        rescue SystemCallError
          next
        end
      end

      # Every gate applies to the file a symlink reaches as well as to the
      # link, and that resolved file is what gets read. Otherwise a tracked
      # `docs/notes.md` link could publish a credential file or a Git-ignored
      # one.
      #
      # @return [String, nil] the resolved path, when it is documentation
      #   inside the repository
      def documentation_target(file_path)
        real = File.realpath(file_path)
        return nil unless real.start_with?("#{@real_root}/")

        real if self.class.doc_path?(real.delete_prefix("#{@real_root}/"))
      end

      # Git rules, for the link and for its target.
      def readable?(relative, target)
        @git_filter ||= GitSourceFilter.new(root: @root)
        [relative, target.delete_prefix("#{@real_root}/")].uniq.none? { |path| @git_filter.skip_reason(path) }
      end

      def skip_oversize(relative)
        Rails.logger.warn("[Woods] Skipping documentation #{relative}: larger than #{MAX_DOC_BYTES} bytes")
        nil
      end

      def build_unit(relative, file_path, source, alias_paths)
        raw = Markdown::LineScan.call(source)
        redacted, redactions = @redaction.call(source, front_matter: raw.front_matter,
                                                       front_matter_lines: raw.front_matter_lines)
        # Everything published is read from the redacted text, so a credential
        # cannot come back as a heading, a mention or a front matter value.
        scan = Markdown::LineScan.call(redacted)

        unit = ExtractedUnit.new(type: :doc, identifier: relative, file_path: file_path)
        unit.namespace = nil
        unit.source_code = redacted
        unit.metadata = metadata_for(relative, scan, redactions).merge(aliases: alias_paths)
        unit.dependencies = []
        unit.chunks = section_chunks(unit)
        unit
      end

      def metadata_for(relative, scan, redactions)
        mentions, truncated = mentions_in(scan.code)
        {
          title: scan.headings.first&.fetch(:text) || File.basename(relative, '.*'),
          headings: scan.headings,
          front_matter: scan.front_matter.to_h { |entry| [entry[:key], entry[:value]] },
          word_count: scan.word_count,
          line_count: scan.line_count,
          links: links_in(relative, scan.links),
          mentions: mentions,
          mentions_truncated: truncated,
          redactions: redactions
        }
      end

      # @return [Array(Array<Hash>, Boolean)] sorted unique candidates and whether the cap dropped any
      def mentions_in(code)
        found = {}
        code.each do |entry|
          DocMentions.scan(entry[:text]).each do |kind, text|
            next if text == 'REDACTED'

            found[[kind, text]] ||= { kind: kind, text: text, line: entry[:line], resolved: false }
          end
        end
        kept = found.values.first(MAX_MENTIONS)
        [kept.sort_by { |mention| [mention[:kind], mention[:text]] }, found.size > MAX_MENTIONS]
      end

      def links_in(relative, links)
        links.map { |link| link[:target] }.uniq.sort.map do |target|
          kind = link_kind(target)
          { target: target, kind: kind, path: (repository_path(relative, target) if kind == 'relative'),
            resolved: false }
        end
      end

      def link_kind(target)
        return 'anchor' if target.start_with?('#')

        URL_SCHEME.match?(target) ? 'external' : 'relative'
      end

      # @return [String, nil] the root-relative path a relative link names, or
      #   nil when it leaves the repository
      def repository_path(relative, target)
        path = target[BEFORE_FRAGMENT].gsub(PERCENT_ESCAPE) { Regexp.last_match(1).hex.chr }
        path = path.force_encoding(Encoding::UTF_8).scrub
        base = path.start_with?('/') ? [] : File.dirname(relative).split('/').reject { |part| part == '.' }
        segments = path.split('/').each_with_object(base) do |segment, parts|
          next if segment.empty? || segment == '.'
          next parts << segment unless segment == '..'
          return nil if parts.empty?

          parts.pop
        end
        segments.empty? ? nil : segments.join('/')
      end

      def section_chunks(unit)
        chunks = Chunking::MarkdownSectionChunker.new(unit).chunk
        chunks.size > 1 ? chunks.map(&:to_h) : []
      end
    end
  end
end
