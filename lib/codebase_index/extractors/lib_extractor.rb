# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # LibExtractor handles extraction of Ruby files from lib/.
    #
    # The lib/ directory contains application infrastructure that sits outside
    # Rails' app/ convention: custom middleware, client wrappers, utility classes,
    # domain-specific libraries, and framework extensions. These are often heavily
    # referenced but invisible to app/-only extractors.
    #
    # Excludes:
    # - lib/tasks/ — handled by RakeTaskExtractor
    # - lib/generators/ — Rails generator scaffolding, not application code
    #
    # Handles:
    # - Plain Ruby classes (with or without inheritance)
    # - Module-only files (standalone modules without a class)
    # - Namespaced classes (e.g., lib/external/analytics.rb → External::Analytics)
    # - Files with multiple class definitions
    #
    # @example
    #   extractor = LibExtractor.new
    #   units = extractor.extract_all
    #   analytics = units.find { |u| u.identifier == "External::Analytics" }
    #   analytics.metadata[:entry_points]  # => ["call"]
    #   analytics.metadata[:parent_class]  # => nil
    #
    class LibExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Root directory to scan
      LIB_DIRECTORY = 'lib'

      # Subdirectories to exclude from extraction
      EXCLUDED_SEGMENTS = %w[/tasks/ /generators/].freeze

      def initialize
        @lib_dir = Rails.root.join(LIB_DIRECTORY)
      end

      # Extract all lib units from lib/**/*.rb (excluding tasks and generators).
      #
      # @return [Array<ExtractedUnit>] List of lib units
      def extract_all
        return [] unless @lib_dir.directory?

        Dir[@lib_dir.join('**/*.rb')].filter_map do |file|
          next if excluded_path?(file)

          extract_lib_file(file)
        end
      end

      # Extract a single lib file.
      #
      # Returns nil if the file cannot be read or yields no extractable unit.
      # Module-only files are extracted (unlike some other extractors) since
      # lib/ commonly contains standalone utility modules.
      #
      # @param file_path [String] Absolute path to the Ruby file
      # @return [ExtractedUnit, nil] The extracted unit or nil on failure
      def extract_lib_file(file_path)
        source = File.read(file_path)

        class_name = infer_class_name(file_path, source)
        return nil unless class_name

        unit = ExtractedUnit.new(
          type: :lib,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace    = extract_namespace(class_name)
        unit.source_code  = annotate_source(source, class_name)
        unit.metadata     = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract lib file #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Path Filtering
      # ──────────────────────────────────────────────────────────────────────

      # Return true when the file path falls inside an excluded subdirectory.
      #
      # @param file_path [String] Absolute path to the file
      # @return [Boolean]
      def excluded_path?(file_path)
        EXCLUDED_SEGMENTS.any? { |seg| file_path.include?(seg) }
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class / Module Name Inference
      # ──────────────────────────────────────────────────────────────────────

      # Infer the primary constant name from source or fall back to file path.
      #
      # For files with a class definition, combines outer module namespaces
      # with the class name. For module-only files, uses the outermost module
      # name (joined with inner modules). Falls back to path-based camelize
      # when neither is present.
      #
      # @param file_path [String] Absolute path to the file
      # @param source [String] Ruby source code
      # @return [String, nil] The inferred constant name, or nil for empty files
      def infer_class_name(file_path, source)
        return nil if source.strip.empty?

        # Class definition — combine outer modules + class name
        class_match = source.match(/^\s*class\s+([\w:]+)/)
        if class_match
          base = class_match[1]
          return base if base.include?('::')

          namespaces = source.scan(/^\s*module\s+([\w:]+)/).flatten
          return namespaces.any? ? "#{namespaces.join('::')}::#{base}" : base
        end

        # Module-only file — use the outermost module chain
        modules = source.scan(/^\s*module\s+([\w:]+)/).flatten
        return modules.join('::') if modules.any?

        # Fall back to path-based naming
        path_based_class_name(file_path)
      end

      # Derive a constant name from a lib/ file path.
      #
      # lib/external/analytics.rb      => External::Analytics
      # lib/json_api/serializer.rb      => JsonApi::Serializer
      # lib/my_gem.rb                   => MyGem
      #
      # @param file_path [String] Absolute path to the file
      # @return [String] Camelize-derived constant name
      def path_based_class_name(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative
          .sub(%r{^lib/}, '')
          .sub('.rb', '')
          .split('/')
          .map(&:camelize)
          .join('::')
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Prepend a summary annotation header to the source.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The inferred constant name
      # @return [String] Annotated source
      def annotate_source(source, class_name)
        parent = extract_parent_class(source)
        entry_points = detect_entry_points(source)
        parent_label = parent || 'none'

        annotation = <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Lib: #{class_name.ljust(65)}║
          # ║ Parent: #{parent_label.ljust(61)}║
          # ║ Entry Points: #{entry_points.join(', ').ljust(55)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the metadata hash for a lib unit.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The inferred constant name
      # @return [Hash] Lib unit metadata
      def extract_metadata(source, _class_name)
        {
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          parent_class: extract_parent_class(source),
          loc: count_loc(source),
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size,
          entry_points: detect_entry_points(source)
        }
      end

      # Extract the parent class name from a class definition.
      #
      # @param source [String] Ruby source code
      # @return [String, nil] Parent class name or nil
      def extract_parent_class(source)
        match = source.match(/^\s*class\s+[\w:]+\s*<\s*([\w:]+)/)
        match ? match[1] : nil
      end

      # Count non-blank, non-comment lines of code.
      #
      # @param source [String] Ruby source code
      # @return [Integer] LOC count
      def count_loc(source)
        source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
      end

      # Detect common entry point methods.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Entry point method names
      def detect_entry_points(source)
        points = []
        points << 'call'    if source.match?(/def (self\.)?call\b/)
        points << 'perform' if source.match?(/def (self\.)?perform\b/)
        points << 'execute' if source.match?(/def (self\.)?execute\b/)
        points << 'run'     if source.match?(/def (self\.)?run\b/)
        points << 'process' if source.match?(/def (self\.)?process\b/)
        points.empty? ? ['unknown'] : points
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the dependency array using common dependency scanners.
      #
      # @param source [String] Ruby source code
      # @return [Array<Hash>] Dependency hashes with :type, :target, :via
      def extract_dependencies(source)
        deps = scan_common_dependencies(source)
        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
