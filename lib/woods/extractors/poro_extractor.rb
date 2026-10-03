# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'source_nesting'
require_relative '../source_references/collector'
require_relative 'standalone_module_discovery'
require_relative 'assigned_value_discovery'
require_relative '../source_references/runtime_lookup'
require_relative 'class_families'
require_relative 'constant_assignments'
require_relative '../path_dispatcher'

module Woods
  module Extractors
    # PoroExtractor handles plain Ruby object extraction from app/models/ and
    # from Ruby no other extractor claims (helpers, view models, constraints,
    # app-local libraries, non-component Ruby beside components).
    #
    # Scans app/models/ for Ruby files that define classes which are NOT
    # ActiveRecord descendants (those are handled by ModelExtractor). Captures
    # value objects, form objects, CurrentAttributes subclasses, Struct.new
    # wrappers, and any other non-AR class living alongside AR models. The
    # wider sweep follows `Woods.configuration.unclaimed_ruby_paths` and
    # {PathDispatcher.poro_path?}, so full and incremental runs agree per file.
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

      # A `def` at the start of a line. `[ \t]*+` never crosses a newline and
      # never backtracks, so blank-line runs stay linear.
      OWN_METHOD_DEFINITION = /^[ \t]*+def\s/

      # A `class` or `module` keyword opening a line (`class << self` included).
      DECLARATION_LINE = /^[ \t]*+(?:class|module)\b/

      # Value-class factories AssignedValueDiscovery can promote to a unit.
      VALUE_CLASS_CONSTRUCTOR = /\b(?:Struct\.new|Data\.define)\b/

      # The `app/<directory>/` prefix of a root-relative path.
      APP_DIRECTORY_PREFIX = %r{\Aapp/[^/]++/}

      # Marks a unit found outside app/models by the unclaimed-Ruby sweep.
      SWEEP_MARKER = 'unclaimed_sweep'

      # Marks a unit from a path another extractor owns but emitted nothing for.
      FALLBACK_MARKER = 'owner_fallback'

      def initialize
        @models_dir = Rails.root.join('app/models')
      end

      # A run can hand in a {SourceReferences::MemoCollector} shared with the
      # source-reference pass, so each file is parsed once per run.
      attr_writer :collector

      # @return [#call] the parser for every file this extractor reads
      def collector
        @collector ||= SourceReferences::Collector.new
      end

      # Extract all PORO units from app/models/.
      #
      # Filters out ActiveRecord descendants by name so we don't duplicate
      # what ModelExtractor already produces. Concerns/ subdir is also skipped.
      #
      # @return [Array<ExtractedUnit>] List of PORO units
      def extract_all
        ar_names = ActiveRecord::Base.descendants.filter_map(&:name).to_set

        @module_discovery = StandaloneModuleDiscovery.new
        swept_files.flat_map { |file| extract_poro_units(file, ar_names: ar_names) }
      end

      # Every file this extractor scans: app/models outside concerns, plus the
      # configured unclaimed globs minus anything another file rule owns.
      #
      # @return [Array<String>] absolute paths, sorted
      def swept_files
        root = Rails.root.to_s
        globs = [MODELS_GLOB, *Woods.configuration&.unclaimed_ruby_paths]
        globs.flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: root) }
             .uniq.sort.select { |relative| PathDispatcher.poro_path?(relative) }
             .map { |relative| File.join(root, relative) }
      end

      # Owned Ruby under the sweep globs, each with the extractors that own it.
      # Extractor runs {#extract_fallback_units} on a path when none of its
      # owners emitted a unit for it.
      #
      # @return [Hash{String => Array<Symbol>}] absolute path => owning extractor keys
      def fallback_files
        root = Rails.root.to_s
        Array(Woods.configuration&.unclaimed_ruby_paths)
          .flat_map { |glob| Dir.glob(glob, File::FNM_EXTGLOB, base: root) }
          .uniq.sort.select { |relative| PathDispatcher.fallback_candidate?(relative) }
          .to_h { |relative| [File.join(root, relative), PathDispatcher.claiming_keys_for(relative)] }
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
        extract_units(file_path, ar_names, fallback: false)
      end

      # Units for a path another extractor's file rule owns but emitted nothing
      # for. The same class-family exclusion and canonical-ownership proof as
      # the sweep apply; units carry {FALLBACK_MARKER}.
      #
      # @param file_path [String] original Ruby file
      # @param ar_names [Set<String>] Active Record identities to exclude
      # @return [Array<ExtractedUnit>]
      def extract_fallback_units(file_path, ar_names: Set.new)
        extract_units(file_path, ar_names, fallback: true)
      end

      # Recompute unclaimed module identities for includer-only reconciliation.
      # The root pipeline owns cross-family migration and source-consumption.
      #
      # @return [Hash<String, Array<ExtractedUnit>>] absolute paths and module units
      def standalone_modules
        @module_discovery = StandaloneModuleDiscovery.new
        swept_files.each_with_object({}) do |file, result|
          # Without the keyword the file declares no module; skip the parse.
          next unless File.read(file).match?(/\bmodule\s/)

          units = extract_standalone_module_file(file)
          result[file] = units unless units.empty?
        end
      end

      # The skip reason the file decides on its own, before any ownership or
      # runtime question: `parse_error`, `no_declaration` or `namespace_only`.
      #
      # @param file_path [String] absolute path of a file that produced no unit
      # @return [String, nil] nil when the file declares something of its own
      def static_skip_reason(file_path)
        source, analysis, declarations = skip_inputs(file_path)
        return 'parse_error' if analysis['parse_error']
        return 'no_declaration' if declarations.empty? && ConstantAssignments.new.call(source).empty?

        'namespace_only' if declarations.any? && namespace_only?(source, declarations)
      end

      # Why a scanned file yields no unit. See {Woods::SkippedFiles} for the reasons.
      #
      # @param file_path [String] absolute path of a file that produced no unit
      # @return [String] skip reason
      def skip_reason(file_path)
        static = static_skip_reason(file_path)
        return static if static

        _source, _analysis, declarations = skip_inputs(file_path)
        family = declarations.select { |declaration| declaration['kind'] == 'class' }
                             .map { |declaration| declaration['owner'] }.uniq
                             .filter_map { |identifier| runtime_family(identifier) }.first
        family ? "rejected_by:#{family}" : 'not_owned'
      end

      private

      # A file whose only declarations are a class-family class and its
      # namespace wrappers cannot yield a PORO unit, and deciding that needs no
      # parse. Most swept controller, mailer and component files are this shape.
      def family_owned_file?(file_path, source)
        return false if source.match?(VALUE_CLASS_CONSTRUCTOR)

        governed = managed_constant_path(file_path.to_s)
        return false unless governed

        segments = governed.split('::')
        return false if source.scan(DECLARATION_LINE).size > segments.size
        return false unless runtime_family(governed)

        discovery = (@module_discovery ||= StandaloneModuleDiscovery.new)
        (1...segments.size).none? { |depth| discovery.owns?(segments.first(depth).join('::'), file_path) }
      end

      def skip_inputs(file_path)
        source = File.read(file_path)
        analysis = collector.call(source)
        declarations = analysis.fetch('declarations').select { |declaration| declaration.fetch('singleton_depth', 0).zero? }
        [source, analysis, declarations]
      end

      def extract_units(file_path, ar_names, fallback:)
        source = File.read(file_path)
        return [] if family_owned_file?(file_path, source)

        analysis = collector.call(source)
        discovery = (@module_discovery ||= StandaloneModuleDiscovery.new)
        proof = fallback || swept_path?(file_path)
        primary = extract_class_unit(file_path, source, ar_names, analysis, proof: proof)
        nested = primary ? [] : nested_class_units(file_path, source, ar_names, analysis)
        modules = discovery.call(file_path, analysis: analysis, admit: fallback)
                           .map { |record| module_unit(file_path, source, record) }
        units = [primary, *nested, *modules, *constant_units(file_path, source, analysis)].compact
        return mark(units, FALLBACK_MARKER) if fallback

        swept_path?(file_path) ? mark(units, SWEEP_MARKER) : units
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract PORO #{file_path}: #{e.message}")
        []
      end

      # Nodes that give a module body content of its own.
      CONTENT_NODES = [Prism::DefNode, Prism::ClassNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode,
                       Prism::ConstantOrWriteNode, Prism::ConstantPathOrWriteNode, Prism::BlockNode].freeze
      private_constant :CONTENT_NODES

      def namespace_only?(source, declarations)
        return false unless declarations.all? { |declaration| declaration['kind'] == 'module' }

        pending = [Prism.parse(source).value]
        until pending.empty?
          node = pending.pop
          return false if CONTENT_NODES.any? { |type| node.is_a?(type) }

          pending.concat(node.compact_child_nodes)
        end
        true
      end

      def extract_standalone_module_file(file)
        source = File.read(file)
        analysis = collector.call(source)
        units = @module_discovery.call(file, analysis: analysis).map { |record| module_unit(file, source, record) }
        swept_path?(file) ? mark(units, SWEEP_MARKER) : units
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract standalone module #{file}: #{e.message}")
        []
      end

      def extract_class_unit(file_path, source, ar_names, analysis, proof:)
        return nil unless class_source?(source, analysis)

        class_name = infer_class_name(file_path, source, analysis)
        return nil unless class_name
        return nil if ar_names.include?(class_name)
        return nil if analysis.fetch('declarations').any? do |declaration|
          declaration['owner'] == class_name && declaration['kind'] == 'module'
        end
        return nil if runtime_family(class_name)
        return nil if proof && !@module_discovery.owns?(class_name, file_path)

        unit = ExtractedUnit.new(type: :poro, identifier: class_name, file_path: file_path)
        parent_class = extract_parent_class(source, class_name)
        unit.namespace = extract_namespace(class_name)
        unit.source_code = annotate_source(source, class_name, parent_class)
        unit.metadata = extract_metadata(source, parent_class)
        unit.dependencies = extract_dependencies(source)
        unit
      end

      # A namespace file's governed constant is a module, so no class is
      # primary. Classes nested only in modules, with a method of their own
      # and canonically declared here, are units; bodiless helpers
      # (`class Error < StandardError; end`) are not.
      def nested_class_units(file_path, source, ar_names, analysis)
        declarations = analysis.fetch('declarations')
        modules = declarations.select { |declaration| declaration['kind'] == 'module' }.to_set { |d| d['owner'] }
        lines = source.lines
        candidates = declarations.select do |declaration|
          declaration['kind'] == 'class' && declaration.fetch('singleton_depth', 0).zero? &&
            !declaration['constructor'] && !modules.include?(declaration['owner']) &&
            !ar_names.include?(declaration['owner']) &&
            declaration.fetch('enclosing_nesting', []).all? { |name| modules.include?(name) } &&
            lines[(declaration['line'] - 1)...declaration['end_line']].join.match?(OWN_METHOD_DEFINITION)
        end
        @module_discovery.owned_classes(file_path, candidates).filter_map do |identifier|
          next if runtime_family(identifier)

          declaration = candidates.find { |candidate| candidate['owner'] == identifier }
          nested_class_unit(file_path, source, identifier, lines[(declaration['line'] - 1)...declaration['end_line']].join)
        end
      end

      # @return [Symbol, nil] the class-discovered extractor owning a loaded class
      def runtime_family(identifier)
        @lookup ||= SourceReferences::RuntimeLookup.new
        value = @lookup.call("::#{identifier}", allow_private: true)[:value]
        ClassFamilies.owner_of(value, @lookup) if @lookup.class_object?(value)
      end

      # Outside app/models, a class unit needs the same canonical-ownership
      # proof modules get, so two files never mint one identifier.
      def swept_path?(file_path)
        !File.expand_path(file_path).start_with?("#{File.expand_path(@models_dir)}/")
      end

      def mark(units, marker)
        units.each { |unit| unit.metadata = unit.metadata.merge(discovered_via: marker) }
      end

      # A file with no class or module body can still own top-level constants
      # (`Pattern = /.../`). Each owned, non-module assignment is a unit.
      def constant_units(file_path, source, analysis)
        return [] if analysis['parse_error'] || analysis.fetch('declarations').any?

        lines = source.lines
        ConstantAssignments.new.call(source).filter_map do |record|
          next unless owned_constant?(record[:identifier], file_path)

          constant_unit(file_path, record, lines[(record[:line] - 1)...record[:end_line]].join)
        end
      end

      def owned_constant?(identifier, file_path)
        @lookup ||= SourceReferences::RuntimeLookup.new
        @lookup.call("::#{identifier}", allow_private: true)[:reason] == 'non_module_constant' &&
          @module_discovery.owns?(identifier, file_path)
      end

      def constant_unit(file_path, record, body)
        identifier = record[:identifier]
        unit = ExtractedUnit.new(type: :poro, identifier: identifier, file_path: file_path)
        unit.namespace = extract_namespace(identifier)
        unit.source_code = annotate_source(body, identifier, nil)
        unit.metadata = { ruby_kind: 'constant', value_kind: record[:value_kind], parent_class: nil,
                          public_methods: [], class_methods: [], initialize_params: [], method_count: 0,
                          loc: count_loc(body) }
        unit.dependencies = extract_dependencies(body)
        unit
      end

      def nested_class_unit(file_path, source, identifier, body)
        unit = ExtractedUnit.new(type: :poro, identifier: identifier, file_path: file_path)
        parent_class = extract_parent_class(source, identifier)
        unit.namespace = extract_namespace(identifier)
        unit.source_code = annotate_source(body, identifier, parent_class)
        unit.metadata = extract_metadata(body, parent_class)
        unit.dependencies = extract_dependencies(body)
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
      def infer_class_name(file_path, source, analysis = collector.call(source))
        # Explicit class keyword — Zeitwerk-governed naming first (G-1), then
        # enclosing modules joined by position (#174)
        assigned = AssignedValueDiscovery.new.call(file_path, analysis: analysis,
                                                              expected: managed_constant_path(file_path.to_s))
        return assigned if assigned

        qualified = governed_class_name(file_path, source) || qualified_first_class_name(source)
        return qualified if qualified

        # Preserve historical top-level assignment lookup identities, including
        # named Struct aliases. Reference targets still require verified ownership.
        assignments = analysis.fetch('declarations').select { |record| record['constructor'] }
        unless assignments.empty?
          legacy = assignments.find do |record|
            record['enclosing_nesting'].empty? && record.fetch('singleton_depth', 0).zero?
          end
          return legacy && legacy['owner']
        end

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
          .sub(APP_DIRECTORY_PREFIX, '')
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
