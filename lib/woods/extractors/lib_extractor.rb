# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'source_nesting'
require_relative '../source_references/collector'
require_relative 'assigned_value_discovery'
require_relative '../source_contributors'
require_relative '../source_references/registry'
require_relative 'class_declarations'

module Woods
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
      include SourceNesting

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
        library_groups.flat_map { |group| aggregate(group) || group.map { |entry| copy_unit(entry[:unit]) } }
      end

      # Extract the complete library owner containing this physical file.
      #
      # Returns nil when the file yields no extractable unit. Discovery errors
      # or incompatible contributors refuse extraction instead of returning a
      # partial owner. This entry point never loads application source.
      #
      # @param file_path [String] Absolute path to the Ruby file
      # @return [ExtractedUnit, nil] The complete owner or nil when absent
      # @raise [Woods::ExtractionError] when complete ownership cannot be established
      def extract_lib_file(file_path)
        group = library_groups.find { |entries| entries.any? { |entry| entry[:unit].file_path == file_path.to_s } }
        return unless group
        return copy_unit(group.first[:unit]) if group.one?

        aggregate(group) || raise(Woods::ExtractionError, "Ambiguous library owner: #{group.first[:unit].identifier}")
      end

      private

      def library_groups
        @library_groups ||= begin
          files = @lib_dir.directory? ? Dir.glob('**/*.rb', base: @lib_dir).sort : []
          entries = files.filter_map do |relative|
            path = @lib_dir.join(relative).to_s
            next if excluded_path?(path)

            build_file(path)
          end
          if SourceInputs::ConsumerErrors.failed?(self)
            raise Woods::ExtractionError, 'Cannot establish the complete library contributor set after a source failure'
          end

          entries.group_by { |entry| entry[:unit].identifier }.values
        end
      end

      def build_file(file_path)
        source = File.read(file_path, encoding: 'UTF-8')
        raise Woods::ExtractionError, 'Source is not valid UTF-8' unless source.valid_encoding?

        class_name = infer_class_name(file_path, source)
        return nil unless class_name

        unit = ExtractedUnit.new(
          type: :lib,
          identifier: class_name,
          file_path: file_path
        )

        parent_class = extract_parent_class(source, class_name)

        unit.namespace    = extract_namespace(class_name)
        unit.source_code  = annotate_source(source, class_name, parent_class)
        unit.metadata     = extract_metadata(source, parent_class)
        unit.dependencies = extract_dependencies(source)

        { unit: unit, source: source, analysis: SourceReferences::Collector.new.call(source) }
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract lib file #{file_path}: #{e.message}")
        nil
      end

      def copy_unit(original)
        original.dup.tap do |unit|
          unit.metadata = original.metadata.dup
          unit.dependencies = original.dependencies.map(&:dup)
        end
      end

      def aggregate(group)
        return copy_unit(group.first[:unit]) if group.one?
        return unless compatible_contributors?(group)

        primary = group.first[:unit]
        unit = ExtractedUnit.new(type: :lib, identifier: primary.identifier, file_path: primary.file_path)
        unit.namespace = primary.namespace
        unit.source_code = +''
        records = group.map { |entry| append_contributor(unit, entry) }
        unit.metadata = common_facts(group)
        unit.metadata[:source_contributors_version] = SourceContributors::VERSION
        unit.metadata[:source_contributors] = records
        unit.metadata[:defined_in] = records.map { |record| record['file_path'] }
        unit.dependencies = group.flat_map { |entry| entry[:unit].dependencies }.uniq
        unit
      end

      def compatible_contributors?(group)
        units = group.map { |entry| entry[:unit] }
        sources = group.to_h { |entry| [entry[:unit].file_path, entry[:analysis]] }
        registry = SourceReferences::Registry.new(units: units, sources: sources, root: Rails.root)
        kinds = group.map do |entry|
          unit = entry[:unit]
          declarations = entry[:analysis].fetch('declarations', []).select { |decl| decl['owner'] == unit.identifier }
          return false if declarations.empty? || declarations.any? { |decl| decl['constructor'] }
          return false unless registry.owner?(unit.identifier, file_path: unit.file_path)

          declarations.map { |decl| decl['kind'] }.uniq
        end
        kinds.flatten.uniq.one? && compatible_parents?(group)
      end

      def compatible_parents?(group)
        parents = group.flat_map do |entry|
          ClassDeclarations.read(entry[:source]).filter_map do |declaration|
            next unless declaration[:identifier] == entry[:unit].identifier
            next unless declaration[:node].superclass

            parent = ClassDeclarations.parent_name(declaration)
            return false unless parent

            parent.delete_prefix('::')
          end
        end
        parents.uniq.size <= 1
      rescue ClassDeclarations::Unresolved
        false
      end

      def append_contributor(unit, entry)
        path = entry[:unit].file_path.delete_prefix("#{Rails.root}/")
        source = entry[:source]
        unit.source_code << "# Library contributor: #{path}\n"
        start_byte = unit.source_code.bytesize
        start_line = unit.source_code.count("\n") + 1
        unit.source_code << source
        record = { 'file_path' => path, 'source_sha256' => Digest::SHA256.hexdigest(source),
                   'source_start_line' => 1, 'source_end_line' => source.lines.size,
                   'published_start_byte' => start_byte, 'published_end_byte' => unit.source_code.bytesize,
                   'published_start_line' => start_line, 'published_end_line' => start_line + source.lines.size - 1,
                   'facts' => entry[:unit].metadata }
        unit.source_code << "\n\n"
        record
      end

      # Conflicting scalar/list facts remain available per contributor; sorted
      # paths are display order and cannot establish runtime override order.
      def common_facts(group)
        facts = group.first[:unit].metadata.select do |key, value|
          group.all? { |entry| entry[:unit].metadata[key] == value }
        end
        %i[public_methods class_methods entry_points].each do |key|
          facts[key] = group.flat_map { |entry| entry[:unit].metadata.fetch(key) }.uniq
        end
        %i[loc method_count].each { |key| facts[key] = group.sum { |entry| entry[:unit].metadata.fetch(key) } }
        facts
      end

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
      # For files with a class definition, the position-aware nesting scan
      # (SourceNesting) qualifies the first `class` declaration with the
      # modules actually open at that position — a helper module nested
      # inside the class, or a sibling module that closed before the class
      # opened, no longer pollutes the identifier (#174). For module-only
      # files, uses the outer module chain (namespace wrappers joined),
      # ignoring inner modules declared after body content. Falls back to
      # path-based camelize when neither is present.
      #
      # @param file_path [String] Absolute path to the file
      # @param source [String] Ruby source code
      # @return [String, nil] The inferred constant name, or nil for empty files
      def infer_class_name(file_path, source)
        return nil if source.strip.empty?

        # Class definition — Zeitwerk-governed naming first (G-1), then the
        # position-aware nesting scan, which qualifies the first `class`
        # declaration with the modules actually open at that position — a
        # helper module nested inside the class, or a sibling module that
        # closed before the class opened, no longer pollutes the identifier
        # (#174). lib/ files are typically unmanaged, so the governed lookup
        # returns nil and the source scan decides.
        analysis = SourceReferences::Collector.new.call(source)
        expected = managed_constant_path(file_path.to_s) || path_based_class_name(file_path)
        assigned = AssignedValueDiscovery.new.call(file_path, analysis: analysis, expected: expected,
                                                              preserve_modules: true)
        return assigned if assigned

        qualified = governed_class_name(file_path, source) || qualified_first_class_name(source)
        return qualified if qualified

        # Module-only file — the outer module chain
        module_name = qualified_outer_module_name(source)
        return module_name if module_name

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
      # @param parent_class [String, nil] Selected explicit parent
      # @return [String] Annotated source
      def annotate_source(source, class_name, parent_class)
        entry_points = detect_entry_points(source)
        parent_label = parent_class || 'none'

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
      # @param parent_class [String, nil] Selected explicit parent
      # @return [Hash] Lib unit metadata
      def extract_metadata(source, parent_class)
        {
          public_methods: extract_public_methods(source),
          class_methods: extract_class_methods(source),
          initialize_params: extract_initialize_params(source),
          parent_class: parent_class,
          loc: count_loc(source),
          method_count: source.scan(/def\s+(?:self\.)?\w+/).size,
          entry_points: detect_entry_points(source)
        }
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
        consolidate_dependencies(deps)
      end
    end
  end
end
