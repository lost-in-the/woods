# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # ConcernExtractor handles ActiveSupport::Concern module extraction.
    #
    # Concerns are mixins that extend model and controller behavior.
    # They live in `app/models/concerns/` and `app/controllers/concerns/`.
    #
    # We extract:
    # - Module name and namespace
    # - Included/extended hooks and class methods block
    # - Instance methods and class methods added by the concern
    # - Dependencies on models and other concerns
    #
    # @example
    #   extractor = ConcernExtractor.new
    #   units = extractor.extract_all
    #   searchable = units.find { |u| u.identifier == "Searchable" }
    #
    class ConcernExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner

      # Directories to scan for concern modules
      CONCERN_DIRECTORIES = %w[
        app/models/concerns
        app/controllers/concerns
      ].freeze

      def initialize
        @directories = CONCERN_DIRECTORIES.map { |d| Rails.root.join(d) }
                                          .select(&:directory?)
      end

      # Extract all concern modules
      #
      # @return [Array<ExtractedUnit>] List of concern units
      def extract_all
        @directories.flat_map do |dir|
          Dir[dir.join('**/*.rb')].filter_map do |file|
            extract_concern_file(file)
          end
        end
      end

      # Extract a single concern file
      #
      # @param file_path [String] Path to the concern file
      # @return [ExtractedUnit, nil] The extracted unit or nil if not a concern
      def extract_concern_file(file_path)
        source = File.read(file_path)
        module_name = extract_module_name(file_path, source)

        return nil unless module_name
        return nil unless concern_module?(source)

        unit = ExtractedUnit.new(
          type: :concern,
          identifier: module_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(module_name)
        unit.source_code = annotate_source(source, module_name)
        unit.metadata = extract_metadata(source, file_path)
        unit.dependencies = extract_dependencies(source)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract concern #{file_path}: #{e.message}")
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Module Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Extract the module name from source or infer from file path.
      #
      # @param file_path [String] Path to the concern file
      # @param source [String] Ruby source code
      # @return [String, nil] The module name
      def extract_module_name(file_path, source)
        # Try to find the outermost module definition
        modules = source.scan(/^\s*module\s+([\w:]+)/).flatten
        return modules.last if modules.any?

        # Infer from file path
        relative = file_path.sub("#{Rails.root}/", '')
        relative
          .sub(%r{^app/(models|controllers)/concerns/}, '')
          .sub('.rb', '')
          .split('/')
          .map { |segment| segment.split('_').map(&:capitalize).join }
          .join('::')
      end

      # Detect whether source defines an ActiveSupport::Concern or a plain mixin.
      #
      # @param source [String] Ruby source code
      # @return [Boolean]
      def concern_module?(source)
        # ActiveSupport::Concern usage or plain module with methods
        source.match?(/^\s*module\s+/) &&
          (source.match?(/extend\s+ActiveSupport::Concern/) ||
           source.match?(/included\s+do/) ||
           source.match?(/class_methods\s+do/) ||
           source.match?(/def\s+\w+/))
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String] Ruby source code
      # @param module_name [String] The concern module name
      # @return [String] Annotated source
      def annotate_source(source, module_name)
        concern_type = detect_concern_type(source)
        instance_methods = extract_instance_method_names(source)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ Concern: #{module_name.ljust(59)}║
          # ║ Type: #{concern_type.ljust(62)}║
          # ║ Methods: #{instance_methods.join(', ').ljust(59)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String] Ruby source code
      # @param file_path [String] Path to the concern file
      # @return [Hash] Concern metadata
      def extract_metadata(source, file_path)
        {
          concern_type: detect_concern_type(source),
          concern_scope: detect_concern_scope(file_path),
          uses_active_support: source.match?(/extend\s+ActiveSupport::Concern/),
          has_included_block: source.match?(/included\s+do/) || false,
          has_class_methods_block: source.match?(/class_methods\s+do/) || false,
          included_modules: detect_included_modules(source),
          instance_methods: extract_instance_method_names(source),
          class_methods: extract_class_methods(source),
          public_methods: extract_public_methods(source),
          callbacks_defined: detect_callbacks(source),
          scopes_defined: detect_scopes(source),
          validations_defined: detect_validations(source),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') },
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
      end

      # Detect whether this is a model concern, controller concern, or generic.
      #
      # @param source [String] Ruby source code
      # @return [String] One of "active_support", "plain_mixin"
      def detect_concern_type(source)
        if source.match?(/extend\s+ActiveSupport::Concern/)
          'active_support'
        else
          'plain_mixin'
        end
      end

      # Detect concern scope from file path (model vs controller).
      #
      # @param file_path [String] Path to the concern file
      # @return [String] One of "model", "controller", "unknown"
      def detect_concern_scope(file_path)
        if file_path.include?('app/models/concerns')
          'model'
        elsif file_path.include?('app/controllers/concerns')
          'controller'
        else
          'unknown'
        end
      end

      # Extract instance method names (not self. methods).
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Instance method names
      def extract_instance_method_names(source)
        source.scan(/^\s*def\s+(\w+[?!=]?)/).flatten.reject { |m| m.start_with?('self.') }
      end

      # Detect other modules included by this concern.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Module names
      def detect_included_modules(source)
        source.scan(/(?:include|extend)\s+([\w:]+)/).flatten
              .reject { |m| m == 'ActiveSupport::Concern' }
      end

      # Detect callback declarations.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Callback names
      def detect_callbacks(source)
        source.scan(/(before_\w+|after_\w+|around_\w+)\s/).flatten.uniq
      end

      # Detect scope declarations.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Scope names
      def detect_scopes(source)
        source.scan(/scope\s+:(\w+)/).flatten
      end

      # Detect validation declarations.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] Validation types
      def detect_validations(source)
        source.scan(/(validates?(?:_\w+)?)\s/).flatten.uniq
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # @param source [String] Ruby source code
      # @return [Array<Hash>] Dependency hashes
      def extract_dependencies(source)
        # Other concerns included by this concern
        deps = detect_included_modules(source).map do |mod|
          { type: :concern, target: mod, via: :include }
        end

        # Standard dependency scanning
        deps.concat(scan_model_dependencies(source))
        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_job_dependencies(source))

        deps.uniq { |d| [d[:type], d[:target]] }
      end
    end
  end
end
