# frozen_string_literal: true

module Woods
  # Which files are JavaScript/TypeScript source for the `js_module` unit type.
  #
  # One predicate shared by the extractor, the dispatcher rule and the reload
  # policy, so "is this path a module?" has a single answer. It reads
  # +Woods.configuration.javascript_paths+ at call time and falls back to
  # {DEFAULT_GLOBS} when Woods is loaded without its configuration (the
  # fresh-process classifiers).
  #
  # @example
  #   Woods::JavascriptPaths.source?('app/javascript/controllers/clipboard_controller.js') # => true
  #   Woods::JavascriptPaths.source?('app/javascript/vendor/chart.js')                     # => false
  module JavascriptPaths
    # Root-relative globs scanned when +javascript_paths+ is not configured.
    DEFAULT_GLOBS = ['app/javascript/**/*.{js,ts,jsx,tsx,mjs}', 'app/assets/javascripts/**/*.js'].freeze

    # File extensions that count as a module, whatever a glob matches.
    EXTENSIONS = %w[.js .ts .jsx .tsx .mjs].freeze

    # Directory names that hold vendored or generated code, at any depth.
    EXCLUDED_DIRECTORIES = %w[node_modules vendor public dist build builds tmp coverage].freeze

    # Minified bundles and TypeScript declaration files.
    EXCLUDED_SUFFIXES = %w[.min.js .min.mjs .d.ts].freeze

    # `**/` spans directories, `{a,b}` alternation works.
    GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB

    GLOB_CHARACTERS = /[*?\[{]/

    module_function

    # @return [Array<String>] configured globs, or the defaults
    def globs
      configured = Woods.configuration&.javascript_paths if Woods.respond_to?(:configuration)
      configured || DEFAULT_GLOBS
    end

    # @param relative_path [String] Rails.root-relative path
    # @return [Boolean] whether the path is an indexed module source
    def source?(relative_path)
      path = relative_path.to_s
      EXTENSIONS.any? { |ext| path.end_with?(ext) } &&
        EXCLUDED_SUFFIXES.none? { |suffix| path.end_with?(suffix) } &&
        (File.dirname(path).split('/') & EXCLUDED_DIRECTORIES).empty? &&
        globs.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }
    end

    # @param root [String, Pathname] application root
    # @return [Array<String>] root-relative module paths, sorted
    def files(root)
      root = root.to_s
      globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: root) }.uniq.sort.select do |relative|
        source?(relative) && File.file?(File.join(root, relative))
      end
    end

    # Path fragments that disqualify a module, for consumers that can only
    # test substrings (the generated shell predicate).
    #
    # @return [Array<String>]
    def excluded_fragments
      EXCLUDED_DIRECTORIES.map { |directory| "/#{directory}/" } + EXCLUDED_SUFFIXES
    end

    # The literal directory each glob starts from. Bare specifiers such as
    # `controllers/clipboard_controller` resolve against these.
    #
    # @return [Array<String>] sorted, without globs that have no literal prefix
    def directories
      globs.filter_map { |glob| directory_of(glob) }.uniq.sort
    end

    # @param glob [String]
    # @return [String, nil] the segments before the first wildcard
    def directory_of(glob)
      segments = glob.split('/')
      prefix = segments.take_while { |segment| !segment.match?(GLOB_CHARACTERS) }
      prefix.pop if prefix.size == segments.size
      prefix.join('/') unless prefix.empty?
    end

    # @param segment [String] a glob's final path segment
    # @return [Array<String>] the module extensions it can end in, in {EXTENSIONS} order
    def glob_extensions(segment)
      named = segment[/\.\{([^{}]*)\}\z/, 1]&.split(',')&.map { |ext| ".#{ext}" } ||
              [segment[/\.[A-Za-z0-9]+\z/]].compact
      named.empty? ? EXTENSIONS : EXTENSIONS & named
    end

    # Each glob's literal directory with the module extensions its final
    # segment can match, for consumers that test a directory and a suffix
    # (the dispatcher rules the generated shell predicate is projected from).
    # A segment naming no extension (`*`, `**/*`) accepts all of them; one
    # naming only non-module extensions can match nothing and is dropped.
    #
    # @return [Array<Array(String, Array<String>)>] sorted by directory
    def shapes
      globs.filter_map do |glob|
        directory = directory_of(glob)
        extensions = glob_extensions(glob.split('/').last)
        [directory, extensions] if directory && extensions.any?
      end.uniq.sort_by(&:first)
    end

    # @param value [Object] candidate +javascript_paths+ value
    # @return [Array<String>] frozen copy
    # @raise [Woods::ConfigurationError] unless an Array of relative globs
    def validate!(value)
      raise ConfigurationError, "javascript_paths must be an Array, got #{value.inspect}" unless value.is_a?(Array)

      value.each_with_index do |glob, index|
        next if relative_glob?(glob)

        raise ConfigurationError, "javascript_paths[#{index}] must be a relative glob, got #{glob.inspect}"
      end
      value.map { |glob| glob.dup.freeze }.freeze
    end

    # @param glob [Object]
    # @return [Boolean] a non-empty relative pattern that stays inside the root
    def relative_glob?(glob)
      glob.is_a?(String) && !glob.empty? && !glob.start_with?('/') && !glob.split('/').include?('..')
    end
  end
end
