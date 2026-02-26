# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # PoroExtractor handles plain Ruby object extraction from app/models/.
    #
    # Scans app/models/ for Ruby files that define classes which are NOT
    # ActiveRecord descendants (those are handled by ModelExtractor). Captures
    # value objects, form objects, CurrentAttributes subclasses, Struct.new
    # wrappers, and any other non-AR class living alongside AR models.
    #
    # Files under app/models/concerns/ are excluded — those are handled by
    # ConcernExtractor. Module-only files are also excluded.
    #
    # @example
    #   extractor = PoroExtractor.new
    #   units = extractor.extract_all
    #   money = units.find { |u| u.identifier == "Money" }
    #   money.metadata[:parent_class]  # => nil
    #   money.metadata[:method_count]  # => 3
    #
    class PoroExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Glob pattern for all Ruby files in app/models/ (recursive).
      MODELS_GLOB = 'app/models/**/*.rb'

      # Subdirectory to exclude — handled by ConcernExtractor.
      CONCERNS_SEGMENT = '/concerns/'

      def initialize
        @models_dir = Rails.root.join('app/models')
      end

      # Extract all PORO units from app/models/.
      #
      # Filters out ActiveRecord descendants by name so we don't duplicate
      # what ModelExtractor already produces. Concerns/ subdir is also skipped.
      #
      # @return [Array<ExtractedUnit>] List of PORO units
      def extract_all
        return [] unless @models_dir.directory?

        ar_names = ActiveRecord::Base.descendants.filter_map(&:name).to_set

        Dir[Rails.root.join(MODELS_GLOB)].filter_map do |file|
          next if file.include?(CONCERNS_SEGMENT)

          extract_poro_file(file, ar_names: ar_names)
        end
      end

      # Extract a single PORO file.
      #
      # Returns nil if the file is not a PORO (e.g., module-only, no class
      # or PORO pattern found, or the inferred class is an AR descendant).
      #
      # @param file_path [String] Absolute path to the Ruby file
      # @param ar_names [Set<String>] Set of AR descendant names to skip
      # @return [ExtractedUnit, nil] The extracted unit or nil
      def extract_poro_file(file_path, ar_names: Set.new)
        source = File.read(file_path)

        return nil unless poro_file?(source)
        return nil if module_only?(source)

        class_name = infer_class_name(file_path, source)
        return nil unless class_name
        return nil if ar_names.include?(class_name)

        unit = ExtractedUnit.new(
          type: :poro,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace    = extract_namespace(class_name)
        unit.source_code  = annotate_source(source, class_name)
        unit.metadata     = extract_metadata(source, class_name)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract PORO #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # File Classification
      # ──────────────────────────────────────────────────────────────────────

      # Determine whether a file is worth examining as a PORO.
      #
      # A file qualifies if it contains a class definition OR uses one of the
      # common PORO-without-class patterns (Struct.new, Data.define).
      # Plain constant assignments and module-only files are excluded upstream.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def poro_file?(source)
        source.match?(/^\s*class\s+/) ||
          source.match?(/\bStruct\.new\b/) ||
          source.match?(/\bData\.define\b/)
      end

      # Return true when the file defines only modules, no class keyword.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def module_only?(source)
        source.match?(/^\s*module\s+\w+/) && !source.match?(/^\s*class\s+/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class Name Inference
      # ──────────────────────────────────────────────────────────────────────

      # Infer the primary class name from source or fall back to file path.
      #
      # For regular class definitions we parse the first `class Foo` line,
      # joining outer module namespaces when present. For Struct.new / Data.define
      # patterns we read the constant assignment name. Falls back to the
      # Rails camelize convention on the relative path.
      #
      # @param file_path [String] Absolute path to the file
      # @param source [String] Ruby source code
      # @return [String, nil] The inferred class name
      def infer_class_name(file_path, source)
        # Explicit class keyword — combine outer module namespaces + class name
        class_match = source.match(/^\s*class\s+([\w:]+)/)
        if class_match
          base = class_match[1]
          # If already fully qualified (e.g., Order::Update), use as-is
          return base if base.include?('::')

          namespaces = source.scan(/^\s*module\s+([\w:]+)/).flatten
          return namespaces.any? ? "#{namespaces.join('::')}::#{base}" : base
        end

        # Struct.new / Data.define: ConstantName = Struct.new(...)
        struct_match = source.match(/^(\w[\w:]*)\s*=\s*(?:Struct\.new|Data\.define)/)
        return struct_match[1] if struct_match

        # Fall back: derive from file path using Rails naming convention
        path_based_class_name(file_path)
      end

      # Derive a class name from a file path using Rails camelize convention.
      #
      # app/models/order/update.rb => Order::Update
      # app/models/money.rb        => Money
      #
      # @param file_path [String] Absolute path to the file
      # @return [String] Camelize-derived class name
      def path_based_class_name(file_path)
        relative = file_path.sub("#{Rails.root}/", '')
        relative
          .sub(%r{^app/models/}, '')
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
      # @param class_name [String] The class name
      # @return [String] Annotated source
      def annotate_source(source, class_name)
        parent = extract_parent_class(source)
        parent_label = parent || 'none'

        annotation = <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ PORO: #{class_name.ljust(63)}║
          # ║ Parent: #{parent_label.ljust(61)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

        ANNOTATION

        annotation + source
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the metadata hash for a PORO unit.
      #
      # @param source [String] Ruby source code
      # @param class_name [String] The class name
      # @return [Hash] PORO metadata
      def extract_metadata(source, _class_name)
        {
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          parent_class: extract_parent_class(source),
          loc: count_loc(source),
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
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

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build the dependency array for a PORO unit using common scanners.
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
