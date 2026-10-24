# frozen_string_literal: true

module Woods
  module Extractors
    # The files {RakeTaskExtractor} reads, as configured by
    # +config.rake_task_paths+.
    #
    # Each entry is one of three shapes, checked at assignment:
    #
    # * +dir/**/*.ext+: every matching file under +dir+
    # * +dir/*.ext+: matching files directly inside +dir+
    # * +path/to/File+: one file
    #
    # The grammar is that narrow on purpose. {PathDispatcher} rules are
    # fingerprinted as plain data and projected into a shell predicate, so an
    # entry has to reduce to a directory, a suffix and a depth. Ruby files
    # under a configured directory are the tasks' support code (helper
    # modules, core extensions) and belong to the same extractor.
    #
    # @example
    #   RakeTaskPaths.task_file?('rake/deploy.rake')     # => true
    #   RakeTaskPaths.support_file?('rake/lib/shell.rb') # => true
    module RakeTaskPaths
      DEFAULT_PATHS = ['lib/tasks/**/*.rake', 'rake/**/*.rake', 'Rakefile'].freeze

      SUPPORT_EXTENSION = '.rb'

      GLOB_CHARACTERS = %w[* ? [ ] { }].freeze

      module_function

      # @param value [Array<String>] entries in one of the three shapes
      # @return [Array<String>] a frozen, normalized copy
      # @raise [Woods::ConfigurationError] naming the first malformed entry
      def validate!(value)
        raise ConfigurationError, "rake_task_paths must be an Array, got #{value.inspect}" unless value.is_a?(Array)

        value.each_with_index.map do |entry, index|
          parsed = entry.is_a?(String) ? parse(entry.delete_prefix('./')) : nil
          next entry.delete_prefix('./').freeze if parsed

          raise ConfigurationError,
                "rake_task_paths[#{index}] must be a relative file path, `dir/**/*.ext` or `dir/*.ext`, " \
                "got #{entry.inspect}"
        end.freeze
      end

      # @return [Array<String>] the configured entries, or the defaults before configuration exists
      def configured
        (Woods.configuration&.rake_task_paths if Woods.respond_to?(:configuration)) || DEFAULT_PATHS
      end

      # Plain-data attributes for one {PathDispatcher::Rule} per entry.
      #
      # @param paths [Array<String>] validated entries
      # @return [Array<Hash>]
      def rule_attributes(paths = configured)
        entries = paths.map { |path| parse(path) }
        exact = entries.filter_map { |entry| entry[:exact] }
        rules = entries.reject { |entry| entry[:exact] }.flat_map { |entry| directory_rules(entry) }
        exact.empty? ? rules : rules + [{ dirs: [], exact_paths: exact }]
      end

      # @param relative_path [String] root-relative path
      # @return [Boolean] true when an entry names this file as a task file
      def task_file?(relative_path, paths = configured)
        paths.any? { |path| entry_matches?(parse(path), relative_path) }
      end

      # @param relative_path [String] root-relative path
      # @return [Boolean] true for a Ruby file under a configured directory
      def support_file?(relative_path, paths = configured)
        return false unless relative_path.end_with?(SUPPORT_EXTENSION)
        return false if task_file?(relative_path, paths)

        directories(paths).any? { |dir| relative_path.start_with?("#{dir}/") }
      end

      # @param relative_path [String] root-relative path
      # @return [Boolean] true when the extractor reads this file at all
      def covers?(relative_path, paths = configured)
        task_file?(relative_path, paths) || support_file?(relative_path, paths)
      end

      # @param root [Pathname] application root
      # @return [Array<String>] absolute task file paths, sorted
      def task_files(root, paths = configured)
        paths.flat_map { |path| Dir[root.join(path).to_s] }.select { |file| File.file?(file) }.uniq.sort
      end

      # @param root [Pathname] application root
      # @return [Array<String>] absolute support file paths, sorted
      def support_files(root, paths = configured)
        tasks = task_files(root, paths)
        candidates = directories(paths).flat_map { |dir| Dir[root.join(dir, "**/*#{SUPPORT_EXTENSION}").to_s] }
        (candidates.select { |file| File.file?(file) } - tasks).uniq.sort
      end

      # @return [Array<String>] the directory of every glob entry
      def directories(paths = configured)
        paths.filter_map { |path| parse(path)[:dir] }.uniq
      end

      # @param path [String]
      # @return [Hash, nil] +{ exact: }+, or +{ dir:, suffix:, recursive: }+; nil when malformed
      # Parsed once per distinct entry: classification asks for every file a
      # source check visits.
      def parse(path)
        (@parsed ||= {}).fetch(path) { @parsed[path] = parse_entry(path) }
      end

      def parse_entry(path)
        return nil if path.empty? || path.start_with?('/') || path.include?("\0")
        return nil if path.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
        return { exact: path } unless glob?(path)

        head, _, basename = path.rpartition('/')
        suffix = basename.delete_prefix('*')
        recursive = head.end_with?('/**')
        dir = recursive ? head.delete_suffix('/**') : head
        return nil if !basename.start_with?('*') || suffix.empty? || glob?(suffix) || dir.empty? || glob?(dir)

        { dir: dir, suffix: suffix, recursive: recursive }
      end

      def glob?(text)
        GLOB_CHARACTERS.any? { |character| text.include?(character) }
      end

      def entry_matches?(entry, relative_path)
        return entry[:exact] == relative_path if entry[:exact]
        return false unless relative_path.end_with?(entry[:suffix]) && relative_path.start_with?("#{entry[:dir]}/")

        entry[:recursive] || File.dirname(relative_path) == entry[:dir]
      end

      def directory_rules(entry)
        dirs = [entry[:dir]]
        return [{ dirs: dirs, extensions: [entry[:suffix], SUPPORT_EXTENSION].uniq }] if entry[:recursive]

        [{ dirs: dirs, extensions: [entry[:suffix]], recursive: false },
         { dirs: dirs, extensions: [SUPPORT_EXTENSION] }]
      end

      private_class_method :glob?, :entry_matches?, :directory_rules
    end
  end
end
