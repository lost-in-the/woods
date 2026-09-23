# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'source_nesting'
require_relative '../source_references/collector'
require_relative 'standalone_module_discovery'

module Woods
  module Extractors
    # PoroExtractor handles plain Ruby object extraction from app/models/.
    #
    # Scans app/models/ for Ruby files that define classes which are NOT
    # ActiveRecord descendants (those are handled by ModelExtractor). Captures
    # value objects, form objects, CurrentAttributes subclasses, Struct.new
    # wrappers, and any other non-AR class living alongside AR models.
    #
    # Files under app/models/concerns/ are excluded — those are handled by
    # ConcernExtractor. Callable standalone modules use the existing poro type,
    # with explicit module metadata and verified runtime/source ownership.
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
      include SourceNesting

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

        @module_discovery = StandaloneModuleDiscovery.new
        Dir[Rails.root.join(MODELS_GLOB)].flat_map do |file|
          next [] if file.include?(CONCERNS_SEGMENT)

          extract_poro_units(file, ar_names: ar_names)
        end
      end

      # Preserve the historical single-unit return contract. A class remains
      # primary when a file also declares callable standalone modules.
      #
      # @param file_path [String] original Ruby file
      # @param ar_names [Set<String>] Active Record identities to exclude
      # @return [ExtractedUnit, nil] primary class or first standalone module
      def extract_poro_file(file_path, ar_names: Set.new)
        extract_poro_units(file_path, ar_names: ar_names).first
      end

      # Extract every owned unit from one file; incremental dispatch uses this
      # form so a concern and a standalone sibling can share source safely.
      #
      # @param file_path [String] original Ruby file
      # @param ar_names [Set<String>] Active Record identities to exclude
      # @return [Array<ExtractedUnit>] legacy class followed by standalone modules
      def extract_poro_units(file_path, ar_names: Set.new)
        source = File.read(file_path)
        analysis = SourceReferences::Collector.new.call(source)
        primary = extract_class_unit(file_path, source, ar_names, analysis)
        discovery = (@module_discovery ||= StandaloneModuleDiscovery.new)
        modules = discovery.call(file_path, analysis: analysis).map { |record| module_unit(file_path, source, record) }
        [primary, *modules].compact
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract PORO #{file_path}: #{e.message}")
        []
      end

      # Recompute unclaimed module identities for includer-only reconciliation.
      # The root pipeline owns cross-family migration and source-consumption.
      #
      # @return [Hash<String, Array<ExtractedUnit>>] absolute paths and module units
      def standalone_modules
        @module_discovery = StandaloneModuleDiscovery.new
        return {} unless @models_dir.directory?

        Dir[Rails.root.join(MODELS_GLOB)].each_with_object({}) do |file, result|
          next if file.include?(CONCERNS_SEGMENT)

          units = extract_standalone_module_file(file)
          result[file] = units unless units.empty?
        end
      end

      private

      def extract_standalone_module_file(file)
        source = File.read(file)
        analysis = SourceReferences::Collector.new.call(source)
        @module_discovery.call(file, analysis: analysis).map { |record| module_unit(file, source, record) }
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract standalone module #{file}: #{e.message}")
        []
      end

      def extract_class_unit(file_path, source, ar_names, analysis)
        return nil unless class_source?(source, analysis)

        class_name = infer_class_name(file_path, source)
        return nil unless class_name
        return nil if ar_names.include?(class_name)
        return nil if analysis.fetch('declarations').any? do |declaration|
          declaration['owner'] == class_name && declaration['kind'] == 'module'
        end

        unit = ExtractedUnit.new(type: :poro, identifier: class_name, file_path: file_path)
        parent_class = extract_parent_class(source, class_name)
        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name, parent_class)
        unit.metadata = extract_metadata(source, parent_class)
        unit.dependencies = extract_dependencies(source)
        unit
      end

      def module_unit(file_path, source, record)
        identifier = record.fetch(:identifier)
        unit = ExtractedUnit.new(type: :poro, identifier: identifier, file_path: file_path)
        unit.namespace = extract_namespace(identifier)
        unit.source_code = annotate_source(source, identifier, nil)
        unit.metadata = record.except(:identifier).merge(ruby_kind: 'module', parent_class: nil,
                                                         initialize_params: [], loc: count_loc(source))
        # Shared-file regex scans cannot attribute a sibling's references safely.
        # The source-reference pass owns method/body references for these units.
        unit.dependencies = []
        unit
      end

      # ──────────────────────────────────────────────────────────────────────
      # File Classification
      # ──────────────────────────────────────────────────────────────────────

      # Singleton-class syntax does not establish a class-owned unit. Keep
      # legacy Struct/Data handling while requiring an actual class declaration.
      def class_source?(source, analysis)
        # Preserve the legacy single-class excerpt behavior on invalid fragments;
        # no runtime module ownership is inferred from an unsuccessful parse.
        has_class = if analysis['parse_error']
                      source.match?(/^\s*class\s+/)
                    else
                      analysis.fetch('declarations').any? do |declaration|
                        declaration['kind'] == 'class' && declaration.fetch('singleton_depth', 0).zero?
                      end
                    end
        return true if has_class
        return false if source.match?(/^\s*module\s+\w+/)

        source.match?(/\bStruct\.new\b/) || source.match?(/\bData\.define\b/)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class Name Inference
      # ──────────────────────────────────────────────────────────────────────

      # Infer the primary class name from source or fall back to file path.
      #
      # For regular class definitions the position-aware nesting scan
      # (SourceNesting) qualifies the first `class` declaration with the
      # modules actually open at that position — so a helper module nested
      # inside the class, or a sibling module that closed before the class
      # opened, no longer pollutes the identifier (#174). For Struct.new /
      # Data.define patterns we read the constant assignment name. Falls back
      # to the Rails camelize convention on the relative path.
      #
      # @param file_path [String] Absolute path to the file
      # @param source [String] Ruby source code
      # @return [String, nil] The inferred class name
      def infer_class_name(file_path, source)
        # Explicit class keyword — Zeitwerk-governed naming first (G-1), then
        # enclosing modules joined by position (#174)
        qualified = governed_class_name(file_path, source) || qualified_first_class_name(source)
        return qualified if qualified

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
      # @param parent_class [String, nil] Selected explicit parent
      # @return [String] Annotated source
      def annotate_source(source, class_name, parent_class)
        parent_label = parent_class || 'none'

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
      # @param parent_class [String, nil] Selected explicit parent
      # @return [Hash] PORO metadata
      def extract_metadata(source, parent_class)
        {
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          parent_class: parent_class,
          loc: count_loc(source),
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size
        }
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
        consolidate_dependencies(deps)
      end
    end
  end
end
