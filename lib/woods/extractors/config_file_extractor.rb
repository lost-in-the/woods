# frozen_string_literal: true

require 'psych'
require 'set'
require 'strscan'
require 'woods'

require_relative '../source_inputs/consumer_errors'

module Woods
  module Extractors
    # ConfigFileExtractor indexes YAML configuration and application data files.
    #
    # Each file under `Woods.configuration.config_file_paths` becomes one
    # `config_file` unit identified by its root-relative path. The unit records
    # the file's key structure: top-level keys, environment sections, dotted key
    # paths, ERB use and the environment variables the ERB names.
    #
    # The file's text is never published. `source_code` is an outline rendered
    # from the parsed keys, so comments and values cannot reach the index. Leaf
    # values are stored only with `config.config_file_values = true`, and even
    # then a value under a credential-named key, a credential-shaped value and
    # ERB source are replaced by a marker.
    #
    # Secret-bearing files ({.secret_path?}) are never opened, whatever the
    # configured globs say. The check runs on the path a file resolves to as
    # well as the path it was found at, so a symlink cannot rename a secret
    # into the index, and a file that resolves outside the application root is
    # refused. ERB is never evaluated and YAML is read as a syntax tree, so no
    # object is instantiated from file content.
    #
    # @example
    #   units = ConfigFileExtractor.new.extract_all
    #   settings = units.find { |u| u.identifier == 'config/settings.yml' }
    #   settings.metadata[:environments] # => ["development", "production"]
    #
    class ConfigFileExtractor
      # Root-relative globs scanned when `config_file_paths` is not set.
      DEFAULT_PATHS = %w[config/*.yml config/**/*.yml app/data/**/*.yml].freeze

      # Directories the default globs live under.
      DEFAULT_ROOTS = %w[config app/data].freeze

      # Locale files belong to I18nExtractor.
      EXCLUDED_PREFIXES = %w[config/locales/].freeze

      EXTENSIONS = %w[.yml .yaml].freeze

      # Directory segments and basename fragments that mark a secret-bearing file.
      SECRET_DIRECTORIES = %w[config/credentials/].freeze
      SECRET_BASENAME_FRAGMENTS = %w[
        credential secret password passwd token private_key api_key apikey keystore
      ].freeze
      SECRET_SUFFIXES = %w[.enc .key].freeze

      # Key-name fragments whose values are never stored.
      SENSITIVE_KEY_FRAGMENTS = %w[
        pass pwd secret token key credential auth sign salt dsn encrypt cert private
        bearer cookie session hmac jwt license webhook otp
      ].freeze

      ENVIRONMENT_NAMES = %w[development test staging production].freeze

      MAX_BYTES = 1_048_576
      MAX_KEY_PATHS = 2_000
      MAX_VISITS = 50_000
      MAX_DEPTH = 12
      MAX_VALUE_SCAN_BYTES = 4_096
      MAX_VALUE_DISPLAY = 120

      GLOB_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB
      ERB_PLACEHOLDER = '__WOODS_ERB__'
      ERB_MARKER = '[ERB]'
      # Same marker as Woods::Console::CredentialScanner::REDACTED.
      REDACTED = '[REDACTED]'
      ENV_REFERENCE = /ENV(?:\.fetch\(|\[)\s*+["']([A-Za-z_][A-Za-z0-9_]*+)["']/
      # `scheme://user:password@host` in any scheme, which the scanner's
      # database-URL pattern covers for database schemes only.
      URL_USERINFO = %r{://[^\s/:@]++:[^\s/@]++@}
      # An unbroken run this long that mixes letters and digits reads as a
      # generated token, not a setting.
      OPAQUE_RUN = %r{[A-Za-z0-9+/=_-]{20,}+}
      TOP_LEVEL_KEY = /\A([A-Za-z_:][\w.-]*+):(?:\s|\z)/

      class << self
        # Whether a path is a file this extractor would index. A pure function
        # of the path and configuration: it never touches the filesystem, so
        # readers can decide whether an edge has a target without a lookup.
        #
        # @param relative_path [String] Rails.root-relative path
        # @return [Boolean]
        def config_file_path?(relative_path)
          path = relative_path.to_s
          !path.start_with?('/') && !path.split('/').include?('..') &&
            EXTENSIONS.any? { |extension| path.end_with?(extension) } &&
            EXCLUDED_PREFIXES.none? { |prefix| path.start_with?(prefix) } &&
            !secret_path?(path) &&
            configured_paths.any? { |glob| File.fnmatch?(glob, path, GLOB_FLAGS) }
        end

        # Whether a path names a secret-bearing file. Such a file is never
        # opened and never becomes a unit.
        #
        # @param relative_path [String] Rails.root-relative path
        # @return [Boolean]
        def secret_path?(relative_path)
          path = relative_path.to_s.downcase
          basename = File.basename(path)
          SECRET_DIRECTORIES.any? { |directory| path.include?(directory) } ||
            SECRET_SUFFIXES.any? { |suffix| basename.end_with?(suffix) } ||
            SECRET_BASENAME_FRAGMENTS.any? { |fragment| basename.include?(fragment) }
        end

        # @return [Array<String>] the configured root-relative globs
        def configured_paths
          Woods.configuration&.config_file_paths || DEFAULT_PATHS
        end
      end

      def initialize
        # Loaded here, not at require time: the dispatch rules and the reload
        # policy name this class without ever scanning a value.
        require_relative '../console/credential_scanner'
        @root = Rails.root.to_s
        @scanner = Console::CredentialScanner.new
      end

      # Extract every configured YAML file.
      #
      # @return [Array<ExtractedUnit>] config_file units sorted by identifier
      def extract_all
        candidates.filter_map { |relative| extract_config_file(File.join(@root, relative)) }
      end

      # Extract one YAML file.
      #
      # @param file_path [String] absolute path
      # @return [ExtractedUnit, nil] nil when the path is not an indexable config file
      def extract_config_file(file_path)
        relative = file_path.to_s.delete_prefix("#{@root}/")
        return nil unless self.class.config_file_path?(relative) && readable_target?(file_path.to_s)

        build_unit(file_path.to_s, relative)
      rescue StandardError => e
        # The class only: a parser message can quote the text it failed on.
        SourceInputs::ConsumerErrors.log(self, "Failed to extract config file #{relative}: #{e.class}")
        nil
      end

      # @param name [String] raw key text
      # @return [String] the key as published: ERB marked, credential shapes redacted
      def display_key(name)
        text = name.to_s
        return REDACTED if text.bytesize > MAX_VALUE_SCAN_BYTES

        text = text.gsub(ERB_PLACEHOLDER, ERB_MARKER) if text.include?(ERB_PLACEHOLDER)
        @scanner.scan(text).first == text ? text : REDACTED
      end

      # @param name [String] raw key text
      # @return [Boolean] whether values under this key are withheld
      def sensitive_key?(name)
        key = name.to_s.downcase
        SENSITIVE_KEY_FRAGMENTS.any? { |fragment| key.include?(fragment) }
      end

      # @param value [String] raw scalar text
      # @param sensitive [Boolean] whether a key on the path is credential-named
      # @return [String] a single-line, redacted rendering of the value
      def display_value(value, sensitive)
        text = value.to_s
        return REDACTED if sensitive || text.bytesize > MAX_VALUE_SCAN_BYTES
        return ERB_MARKER if text.include?(ERB_PLACEHOLDER)
        return REDACTED unless @scanner.scan(text).first == text
        return REDACTED if text.match?(URL_USERINFO) || opaque?(text)

        text.gsub(/\s+/, ' ')[0, MAX_VALUE_DISPLAY]
      end

      private

      # Whether the file a path resolves to may be opened: a regular file
      # inside the application root that is not secret-bearing under its
      # resolved name either.
      def readable_target?(file_path)
        return false unless File.file?(file_path)

        root = File.realpath(@root)
        target = File.realpath(file_path)
        target.start_with?("#{root}/") && !self.class.secret_path?(target.delete_prefix("#{root}/"))
      rescue SystemCallError
        false
      end

      def candidates
        globs = self.class.configured_paths
        found = globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: @root) }
        found.uniq.sort.select { |relative| self.class.config_file_path?(relative) }
      end

      def build_unit(file_path, relative)
        outline = File.size(file_path) > MAX_BYTES ? oversized_outline : read_outline(file_path)
        unit = ExtractedUnit.new(type: :config_file, identifier: relative, file_path: file_path)
        unit.namespace = File.dirname(relative)
        unit.metadata = outline.fetch(:metadata)
        unit.source_code = render_source(relative, outline)
        unit.dependencies = []
        unit
      end

      def oversized_outline
        { metadata: base_metadata.merge(oversized: true), values: {} }
      end

      def base_metadata
        { format: 'yaml', root_type: 'empty', top_level_keys: [], environments: [], environment_keys: {},
          key_paths: [], key_paths_truncated: false, entry_count: 0, documents: 0, erb: false, env_vars: [],
          values_stored: store_values?, parse_error: false, oversized: false, loc: 0 }
      end

      def store_values?
        Woods.configuration&.config_file_values == true
      end

      def read_outline(file_path)
        text = File.read(file_path, encoding: Encoding::UTF_8)
        return { metadata: base_metadata.merge(parse_error: true), values: {} } unless text.valid_encoding?

        neutral, erb = neutralize_erb(text)
        metadata = base_metadata.merge(erb: erb, env_vars: erb ? env_vars(text) : [], loc: count_loc(neutral))
        walk = Walk.new(self, store_values?)
        parse_into(walk, neutral, metadata)
        { metadata: metadata, values: walk.values }
      end

      def parse_into(walk, neutral, metadata)
        documents = Psych.parse_stream(neutral).children
        walk.call(documents)
        metadata.merge!(walk.metadata, documents: documents.size)
      rescue Psych::SyntaxError
        keys = fallback_top_level_keys(neutral)
        metadata.merge!(parse_error: true, top_level_keys: keys, key_paths: keys,
                        root_type: keys.empty? ? 'empty' : 'mapping')
      end

      # Replace `<%= %>` output tags with a placeholder scalar and drop every
      # other tag, so the YAML structure survives without running any Ruby.
      # One forward pass; an unterminated tag drops the rest of the file.
      #
      # @return [Array(String, Boolean)] neutral text and whether ERB was present
      def neutralize_erb(text)
        return [text, false] unless text.include?('<%')

        output = +''
        scanner = StringScanner.new(text)
        until scanner.eos?
          chunk = scanner.scan_until(/<%/)
          break output << scanner.rest unless chunk

          output << chunk.byteslice(0, chunk.bytesize - 2)
          printing = scanner.peek(1) == '='
          break unless scanner.scan_until(/%>/)

          output << ERB_PLACEHOLDER if printing
        end
        [output, true]
      end

      def env_vars(text)
        text.scan(ENV_REFERENCE).flatten.uniq.sort
      end

      def count_loc(text)
        text.each_line.count do |line|
          stripped = line.strip
          !stripped.empty? && !stripped.start_with?('#')
        end
      end

      def fallback_top_level_keys(text)
        keys = text.each_line.filter_map { |line| line[TOP_LEVEL_KEY, 1] }
        keys.map { |key| display_key(key) }.uniq
      end

      def opaque?(text)
        text.scan(OPAQUE_RUN).any? { |run| run.match?(/[A-Za-z]/) && run.match?(/\d/) }
      end

      def render_source(relative, outline)
        metadata = outline.fetch(:metadata)
        values = outline.fetch(:values)
        mode = metadata[:values_stored] ? 'credential values redacted' : 'key paths only, values omitted'
        lines = ["# Config file: #{relative} (#{mode})"]
        lines << "# Environments: #{metadata[:environments].join(', ')}" if metadata[:environments].any?
        lines << "# ERB environment variables: #{metadata[:env_vars].join(', ')}" if metadata[:env_vars].any?
        metadata[:key_paths].each { |path| lines << (values.key?(path) ? "#{path} = #{values[path]}" : path) }
        lines.join("\n")
      end

      # One pass over a parsed YAML stream. Aliases and merge keys are followed
      # under a visit budget and a path budget, so an alias expansion bomb ends
      # the walk instead of the process.
      class Walk
        attr_reader :values

        # @param extractor [ConfigFileExtractor] key and value rendering
        # @param store_values [Boolean] whether leaf values are recorded
        def initialize(extractor, store_values)
          @extractor = extractor
          @store_values = store_values
          @paths = []
          @seen_paths = Set.new
          @values = {}
          @visits = 0
          @truncated = false
          @anchors = {}
        end

        # @param documents [Array<Psych::Nodes::Document>]
        # @return [void]
        def call(documents)
          @roots = documents.filter_map { |document| document.children.first }
          collect_anchors
          catch(:budget) { @roots.each { |root| walk_root(root) } }
        end

        # @return [Hash] structural metadata for the walked documents
        def metadata
          root = resolve(@roots.first)
          top = top_level_pairs.map { |name, _| name }.uniq
          environments = top & ENVIRONMENT_NAMES
          { root_type: root_type(root), top_level_keys: top, environments: environments,
            environment_keys: environment_keys(environments), key_paths: @paths,
            key_paths_truncated: @truncated, entry_count: root.is_a?(Psych::Nodes::Sequence) ? root.children.size : 0 }
        end

        private

        # Iterative, so a deeply nested document cannot exhaust the stack.
        def collect_anchors
          stack = @roots.dup
          until stack.empty?
            node = stack.pop
            @anchors[node.anchor] = node if node.respond_to?(:anchor) && node.anchor && !node.is_a?(Psych::Nodes::Alias)
            stack.concat(node.children) if node.children
          end
        end

        def root_type(root)
          case root
          when Psych::Nodes::Mapping then 'mapping'
          when Psych::Nodes::Sequence then 'sequence'
          when Psych::Nodes::Scalar then root.value.to_s.empty? ? 'empty' : 'scalar'
          else 'empty'
          end
        end

        def top_level_pairs
          @roots.flat_map do |root|
            node = resolve(root)
            node.is_a?(Psych::Nodes::Mapping) ? catch(:budget) { pairs(node, []) } || [] : []
          end
        end

        def environment_keys(environments)
          sections = top_level_pairs
          environments.to_h do |environment|
            node = resolve(sections.find { |name, _| name == environment }&.last)
            keys = node.is_a?(Psych::Nodes::Mapping) ? catch(:budget) { pairs(node, []) } || [] : []
            [environment, keys.map(&:first).uniq]
          end
        end

        def walk_root(root)
          node = resolve(root)
          case node
          when Psych::Nodes::Mapping then walk_mapping(node, '', 0, false, [])
          when Psych::Nodes::Sequence then walk_sequence(node, '', 0, false, [])
          end
        end

        def walk_mapping(node, prefix, depth, sensitive, trail)
          return if depth >= MAX_DEPTH

          pairs(node, trail).each do |name, value|
            path = prefix.empty? ? name : "#{prefix}.#{name}"
            withheld = sensitive || @extractor.sensitive_key?(name)
            add_path(path)
            descend(value, path, depth + 1, withheld, trail)
          end
        end

        def walk_sequence(node, prefix, depth, sensitive, trail)
          return if depth >= MAX_DEPTH

          node.children.each do |child|
            visit!
            entry = resolve(child)
            walk_mapping(entry, "#{prefix}[]", depth + 1, sensitive, trail) if entry.is_a?(Psych::Nodes::Mapping)
          end
        end

        def descend(value, path, depth, sensitive, trail)
          anchor = value.is_a?(Psych::Nodes::Alias) ? value.anchor : nil
          return if anchor && trail.include?(anchor)

          node = resolve(value)
          inner = anchor ? trail + [anchor] : trail
          case node
          when Psych::Nodes::Mapping then walk_mapping(node, path, depth, sensitive, inner)
          when Psych::Nodes::Sequence then walk_sequence(node, path, depth, sensitive, inner)
          when Psych::Nodes::Scalar then record_value(path, node, sensitive)
          end
        end

        def record_value(path, node, sensitive)
          return unless @store_values && !@values.key?(path)

          @values[path] = @extractor.display_value(node.value, sensitive)
        end

        # A mapping's entries as [published key name, value node], with merge
        # keys (`<<`) replaced in place by the entries they pull in.
        def pairs(node, trail)
          node.children.each_slice(2).flat_map do |key, value|
            visit!
            next merged_pairs(value, trail) if merge_key?(key)

            [[key_name(key), value]]
          end
        end

        def merge_key?(key)
          key.is_a?(Psych::Nodes::Scalar) && key.value == '<<' && !key.quoted
        end

        def merged_pairs(value, trail)
          sources = value.is_a?(Psych::Nodes::Sequence) ? value.children : [value]
          sources.flat_map do |source|
            anchor = source.is_a?(Psych::Nodes::Alias) ? source.anchor : nil
            next [] if anchor && trail.include?(anchor)

            node = resolve(source)
            if node.is_a?(Psych::Nodes::Mapping)
              pairs(node, anchor ? trail + [anchor] : trail)
            else
              []
            end
          end
        end

        def key_name(key)
          key.is_a?(Psych::Nodes::Scalar) ? @extractor.display_key(key.value) : '[complex]'
        end

        def resolve(node)
          node.is_a?(Psych::Nodes::Alias) ? @anchors[node.anchor] : node
        end

        def add_path(path)
          return unless @seen_paths.add?(path)

          exhausted! if @paths.size >= MAX_KEY_PATHS
          @paths << path
        end

        def visit!
          @visits += 1
          exhausted! if @visits > MAX_VISITS
        end

        def exhausted!
          @truncated = true
          throw :budget
        end
      end
    end
  end
end
