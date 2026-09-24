# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'
require_relative 'source_nesting'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # GraphQLExtractor handles graphql-ruby schema, type and mutation extraction.
    #
    # GraphQL schemas are rich in structure — types, fields, arguments,
    # resolvers, and mutations form a typed API layer over the domain.
    # We extract these with runtime introspection when available (via
    # `GraphQL::Schema.types`) and retain limited file-based discovery
    # when graphql-ruby is unavailable.
    #
    # We extract:
    # - Schema classes and object, input, enum, interface, union and scalar types
    # - Mutations and their arguments/return fields
    # - Query fields and resolvers
    # - Standalone resolver classes
    # - Field-level metadata (types, descriptions, complexity, arguments)
    # - Authorization patterns (authorized?, pundit, cancan)
    # - Dependencies on models, services, jobs, and other GraphQL types
    #
    # @example
    #   extractor = GraphQLExtractor.new
    #   units = extractor.extract_all
    #   user_type = units.find { |u| u.identifier == "Types::UserType" }
    #
    class GraphQLExtractor
      include SharedUtilityMethods
      include SharedDependencyScanner
      include SourceNesting

      # Standard directory for graphql-ruby applications
      GRAPHQL_DIRECTORY = 'app/graphql'

      # Token threshold for chunking large types
      CHUNK_THRESHOLD = 1500

      def initialize
        @graphql_dir = defined?(Rails) ? Rails.root.join(GRAPHQL_DIRECTORY) : nil
        @runtime_lookup = SourceReferences::RuntimeLookup.new
        @runtime_discovery_complete = true
        @schema_classes = find_schema_classes
        @query_roots = []
        @runtime_types = load_runtime_types
      end

      # Current application schemas and the named type classes they expose.
      # Incremental reconciliation adds runtime-defined units that the file
      # pass cannot discover and updates known types whose query-root role
      # changed. It does not infer removals from absence in this inventory.
      #
      # Empty when graphql-ruby is not loaded or the app has no schema, which is
      # why the reconciliation must not read absence here as deletion — see
      # `reconcile_removals: false` in {Extractor::CLASS_BASED_DISCOVERY}.
      #
      # @return [Array<Class, Module>]
      def discoverable_classes
        (@schema_classes + @runtime_types.values).uniq(&:name)
      end

      # @return [Boolean] whether every discovered schema exposed its inventory
      def runtime_discovery_complete?
        @runtime_discovery_complete
      end

      # Shared with incremental reconciliation when a schema changes the role
      # of an unchanged type (ordinary object versus query root).
      # @param klass [Class, Module] current loaded GraphQL declaration
      # @return [Symbol, nil] existing public GraphQL unit type
      def runtime_unit_type(klass)
        classify_runtime_type(klass) if current_runtime_class?(klass) && graphql_runtime_class?(klass)
      end

      # Extract all GraphQL types, mutations, queries, and resolvers
      #
      # Returns an empty array when the app has neither an `app/graphql`
      # directory nor a loadable schema class.
      #
      # Without graphql-ruby, the file pass retains its limited source-form
      # fallback. With loaded declarations, verified GraphQL ancestry governs
      # admission; unresolved constants are never autoloaded by this extractor.
      #
      # @return [Array<ExtractedUnit>] List of GraphQL units
      def extract_all
        unless runtime_discovery_complete?
          raise Woods::ExtractionError, 'GraphQL runtime discovery incomplete; fix the logged schema error and retry'
        end
        return [] unless graphql_source_present?

        units = []
        seen_identifiers = Set.new

        # First pass: runtime introspection (most accurate)
        if discoverable_classes.any?
          discoverable_classes.each do |type_class|
            unit = extract_from_runtime_type(type_class)
            next unless unit
            next if seen_identifiers.include?(unit.identifier)

            seen_identifiers << unit.identifier
            units << unit
          end
        end

        # Second pass: governed declarations, including unattached resolvers.
        if @graphql_dir&.directory?
          Dir[@graphql_dir.join('**/*.rb')].each do |file_path|
            unit = extract_graphql_file(file_path)
            next unless unit
            next if seen_identifiers.include?(unit.identifier)

            seen_identifiers << unit.identifier
            units << unit
          end
        end

        units.compact
      end

      # Extract a single GraphQL file
      #
      # @param file_path [String] Absolute path to a .rb file in app/graphql/
      # @return [ExtractedUnit, nil] The extracted unit, or nil if the file
      #   does not contain a recognizable GraphQL class
      def extract_graphql_file(file_path)
        SourceInputs::ConsumerErrors.record(self) unless runtime_discovery_complete?
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name

        runtime_class = loaded_graphql_constant(class_name)
        return nil if runtime_class && !graphql_runtime_class?(runtime_class)
        return nil unless runtime_class || graphql_class?(source)

        # Classify from the resolved runtime class first, matching
        # {#extract_from_runtime_type}'s classifier. Keeps the two passes
        # from disagreeing on a type's unit_type (a mutation that looks like
        # a type by path/regex) and leaving a stale duplicate unit behind.
        # Falls back to the source/path heuristic when nothing resolves
        # (gem not loaded, autoloading not booted).
        unit_type = runtime_class ? classify_runtime_type(runtime_class) : classify_unit_type(file_path, source)

        unit = ExtractedUnit.new(
          type: unit_type,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = build_annotated_source(source, class_name, unit_type, runtime_class)
        unit.metadata = build_metadata(source, class_name, unit_type, runtime_class)
        unit.dependencies = extract_dependencies(source, class_name)
        unit.chunks = build_chunks(unit, runtime_class) if unit.needs_chunking?(threshold: CHUNK_THRESHOLD)

        unit
      rescue StandardError => e
        if defined?(Rails)
          SourceInputs::ConsumerErrors.log(self, "Failed to extract GraphQL file #{file_path}: #{e.message}")
        end
        nil
      end

      # Extract a unit from a runtime-loaded GraphQL type class.
      #
      # Public because {Extractor::CLASS_BASED_DISCOVERY} names it as the
      # graphql entry's `method:` and the reconciler invokes it with
      # `public_send` (#167). Private, it raised NoMethodError for every
      # candidate — swallowed by the reconciler's `rescue StandardError` into a
      # warn — so the incremental path silently added nothing, which is exactly
      # what #167 set out to fix. `spec/extractor_spec.rb` asserts every
      # CLASS_BASED_DISCOVERY method is publicly callable on its real
      # extractor so no future entry can regress the same way.
      #
      # @param type_class [Class] A graphql-ruby type class
      # @return [ExtractedUnit, nil]
      def extract_from_runtime_type(type_class)
        SourceInputs::ConsumerErrors.record(self) unless runtime_discovery_complete?
        return nil unless type_class.respond_to?(:name) && type_class.name
        # Skip anonymous or internal graphql-ruby classes
        return nil if type_class.name.start_with?('GraphQL::')
        return nil unless current_runtime_class?(type_class) && graphql_runtime_class?(type_class)

        file_path = source_file_for_class(type_class)
        source = file_path && File.exist?(file_path) ? File.read(file_path) : ''
        unit_type = classify_runtime_type(type_class)

        unit = ExtractedUnit.new(
          type: unit_type,
          identifier: type_class.name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(type_class.name)
        unit.source_code = build_annotated_source(source, type_class.name, unit_type, type_class)
        unit.metadata = build_metadata(source, type_class.name, unit_type, type_class)
        unit.dependencies = extract_dependencies(source, type_class.name)
        unit.chunks = build_chunks(unit, type_class) if unit.needs_chunking?(threshold: CHUNK_THRESHOLD)

        unit
      rescue StandardError => e
        if defined?(Rails)
          SourceInputs::ConsumerErrors.log(self, "Failed to extract GraphQL type #{type_class.name}: #{e.message}")
        end
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Schema and Runtime Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Does this app have GraphQL source to extract?
      #
      # Note what this does *not* ask: whether graphql-ruby is loaded. See
      # {#extract_all} — the gem enriches the units, it does not gate them.
      #
      # @return [Boolean]
      def graphql_source_present?
        return true if @graphql_dir&.directory?

        @schema_classes.any?
      end

      # Find every current, named application schema. Stale reload descendants
      # and schemas defined in installed gems cannot claim application ownership.
      #
      # @return [Array<Class>]
      def find_schema_classes
        return [] unless defined?(GraphQL::Schema)

        GraphQL::Schema.descendants.select do |klass|
          next false unless klass.name && !klass.name.start_with?('GraphQL::') && current_runtime_class?(klass)

          path = source_file_for_class(klass)
          path.nil? || (File.expand_path(path).start_with?("#{Rails.root}/") && app_source?(path, Rails.root.to_s))
        end.sort_by(&:name)
      rescue StandardError => e
        log_discovery_failure('schema inventory', e)
        []
      end

      # Load types from the runtime schema for introspection
      #
      # @return [Hash{String => Class}] Map of type name to type class
      def load_runtime_types
        types = {}
        @schema_classes.each do |schema|
          query = schema.query if schema.respond_to?(:query)
          schema_types = {}
          schema.types.each do |name, type_class|
            next if name.start_with?('__') || !current_runtime_class?(type_class)
            next unless graphql_runtime_class?(type_class)

            # GraphQL names are schema-local; two schemas may both have Query.
            schema_types[type_class.name] = type_class
          end
          types.merge!(schema_types)
          @query_roots << query if query
        rescue StandardError => e
          log_discovery_failure(schema.name, e)
        end
        types
      end

      def log_discovery_failure(name, error)
        @runtime_discovery_complete = false
        SourceInputs::ConsumerErrors.record(self)
        return unless defined?(Rails)

        Rails.logger.warn("[Woods] GraphQL runtime discovery incomplete for #{name}: #{error.message}")
      end

      def loaded_graphql_constant(name)
        result = @runtime_lookup.call("::#{name}", allow_private: true)
        result[:value] if result[:status] == :resolved
      end

      def current_runtime_class?(klass)
        return false unless @runtime_lookup.module_object?(klass)

        name = @runtime_lookup.reflect(klass, :name)
        name && SourceReferences::RuntimeLookup::CORE_EQUAL.bind(klass).call(loaded_graphql_constant(name))
      end

      def graphql_runtime_class?(klass)
        return false unless defined?(GraphQL::Schema) && @runtime_lookup.module_object?(klass)

        ancestors = @runtime_lookup.reflect(klass, :ancestors)
        return true if ancestors.include?(GraphQL::Schema) && klass != GraphQL::Schema

        %i[Object InputObject Enum Union Scalar Mutation Resolver Interface].any? do |name|
          GraphQL::Schema.const_defined?(name, false) && ancestors.include?(GraphQL::Schema.const_get(name, false))
        end
      end

      # Locate the file this type was defined in, or nil when there is none.
      #
      # Prefer the real definition or method location, including classes built
      # in initializers, over a convention-named file. Fall back only to an
      # existing convention path. A genuinely fileless type keeps nil and stays
      # out of the graph's file_map and path-based deletion sweep.
      #
      # @param klass [Class]
      # @return [String, nil]
      def source_file_for_class(klass)
        actual = resolve_source_location(klass, app_root: Rails.root.to_s, fallback: nil)
        return actual if actual

        convention_path = Rails.root.join("#{GRAPHQL_DIRECTORY}/#{klass.name.underscore}.rb").to_s
        return convention_path if File.exist?(convention_path)

        nil
      end

      # ──────────────────────────────────────────────────────────────────────
      # Classification
      # ──────────────────────────────────────────────────────────────────────

      # Classify unit type from a runtime type class
      #
      # @param type_class [Class]
      # @return [Symbol]
      def classify_runtime_type(type_class)
        if defined?(GraphQL::Schema::Mutation) && type_class < GraphQL::Schema::Mutation
          :graphql_mutation
        elsif defined?(GraphQL::Schema::Resolver) && type_class < GraphQL::Schema::Resolver
          :graphql_resolver
        elsif defined?(GraphQL::Schema::Enum) && type_class < GraphQL::Schema::Enum
          :graphql_type
        elsif defined?(GraphQL::Schema::Union) && type_class < GraphQL::Schema::Union
          :graphql_type
        elsif defined?(GraphQL::Schema::Interface) && type_class.ancestors.include?(GraphQL::Schema::Interface)
          :graphql_type
        elsif defined?(GraphQL::Schema::InputObject) && type_class < GraphQL::Schema::InputObject
          :graphql_type
        elsif defined?(GraphQL::Schema::Scalar) && type_class < GraphQL::Schema::Scalar
          :graphql_type
        elsif defined?(GraphQL::Schema::Object) && type_class < GraphQL::Schema::Object
          # Check if this is the Query root type
          if @query_roots.include?(type_class)
            :graphql_query
          else
            :graphql_type
          end
        else
          :graphql_type
        end
      end

      # Classify unit type from file path and source content
      #
      # @param file_path [String]
      # @param source [String]
      # @return [Symbol]
      def classify_unit_type(file_path, source)
        return :graphql_mutation if file_path.include?('/mutations/')
        return :graphql_resolver if file_path.include?('/resolvers/')

        return :graphql_mutation if source.match?(/<\s*(?:::)?(GraphQL::Schema::Mutation|Mutations::Base|BaseMutation)/)

        return :graphql_resolver if source.match?(/<\s*(?:::)?(GraphQL::Schema::Resolver|Resolvers::Base|BaseResolver)/)

        # Query type is usually the root query object
        return :graphql_query if file_path.match?(/query_type\.rb$/) || source.match?(/class QueryType\b/)

        :graphql_type
      end

      # Check if a source file contains a graphql-ruby class
      #
      # @param source [String]
      # @return [Boolean]
      def graphql_class?(source)
        source.match?(/<\s*(?:::)?GraphQL::Schema(?:\b(?!::)|::(?:Object|InputObject|Enum|Union|Scalar|Mutation|Resolver|Interface|RelayClassicMutation)\b)/) ||
          source.match?(/< (Types::Base\w+|Base(Type|InputObject|Enum|Union|Scalar|Mutation|Resolver|Interface))/) ||
          source.match?(/< (Mutations::Base|Resolvers::Base)/) ||
          source.match?(/include GraphQL::Schema::Interface/) ||
          (source.include?('field :') && source.match?(/< .*Type\b/))
      end

      # ──────────────────────────────────────────────────────────────────────
      # Class Name and Namespace
      # ──────────────────────────────────────────────────────────────────────

      # Extract the fully-qualified class name from source or file path
      #
      # The identifier is the *outermost* class: the first `class` declaration
      # qualified by the modules actually open at that position, via the
      # position-aware nesting scanner ({SourceNesting}, #174). Declarations
      # after the first `class` are nested — joining every declaration in the
      # file made a mutation with an inner `class InvalidInput < StandardError`
      # identify as `Mutations::CreateUser::InvalidInput`, so the file-pass
      # unit never deduped against the runtime unit in {#extract_all}:
      # double-indexing with graphql-ruby loaded, dangling edges without it
      # (#202). Tracking nesting by position also stops a sibling module that
      # closed *before* the class opened from polluting the prefix — the old
      # end-blind scan turned `module Helpers ... end; module Mutations; class
      # CreateUser` into `Helpers::Mutations::CreateUser`. Module-only files
      # (e.g. interfaces) keep their identifier via the outer module chain.
      #
      # @param file_path [String]
      # @param source [String]
      # @return [String, nil]
      def extract_class_name(file_path, source)
        # Zeitwerk-governed naming first (G-1) — managed graphql/ files are
        # named for the constant their path spells, and the expected path can
        # only match the outer, file-named declaration, so the #202
        # outermost-class contract below is preserved by construction. Then
        # the position-aware nesting scan (#174), then the outer module
        # chain for module-only files (interfaces).
        governed_class_name(file_path, source) ||
          qualified_first_class_name(source) || qualified_outer_module_name(source)
      rescue StandardError
        # Fall back to convention from file path
        return nil unless defined?(Rails)

        file_path
          .sub("#{Rails.root.join(GRAPHQL_DIRECTORY)}/", '')
          .sub('.rb', '')
          .camelize
      end

      # ──────────────────────────────────────────────────────────────────────
      # Source Annotation
      # ──────────────────────────────────────────────────────────────────────

      # Build annotated source with a descriptive header
      #
      # @param source [String] Raw file contents
      # @param class_name [String]
      # @param unit_type [Symbol]
      # @param runtime_class [Class, nil]
      # @return [String]
      def build_annotated_source(source, class_name, unit_type, runtime_class)
        field_count = count_fields(source, runtime_class)
        argument_count = count_arguments(source, runtime_class)

        type_label = format_type_label(unit_type)

        <<~ANNOTATION
          # ╔═══════════════════════════════════════════════════════════════════════╗
          # ║ #{type_label}: #{class_name.ljust(71 - type_label.length - 4)}║
          # ║ Fields: #{field_count.to_s.ljust(4)} | Arguments: #{argument_count.to_s.ljust(42)}║
          # ╚═══════════════════════════════════════════════════════════════════════╝

          #{source}
        ANNOTATION
      end

      # Human-readable label for unit type
      #
      # @param unit_type [Symbol]
      # @return [String]
      def format_type_label(unit_type)
        case unit_type
        when :graphql_mutation then 'GraphQL Mutation'
        when :graphql_query then 'GraphQL Query'
        when :graphql_resolver then 'GraphQL Resolver'
        else 'GraphQL Type'
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Metadata Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Build comprehensive metadata for a GraphQL unit
      #
      # @param source [String]
      # @param class_name [String]
      # @param unit_type [Symbol]
      # @param runtime_class [Class, nil]
      # @return [Hash]
      def build_metadata(source, class_name, _unit_type, runtime_class)
        {
          # GraphQL classification
          graphql_kind: detect_graphql_kind(source, runtime_class),
          parent_class: extract_parent_class(source, class_name),

          # Fields and arguments
          fields: extract_fields(source, runtime_class),
          arguments: extract_arguments(source, runtime_class),

          # Interfaces and connections
          interfaces: extract_interfaces(source, runtime_class),
          connections: extract_connections(source),

          # Resolver info
          resolver_classes: extract_resolver_references(source),

          # Authorization
          authorization: extract_authorization(source),

          # Complexity
          complexity: extract_complexity(source),

          # Enum values (if applicable)
          enum_values: extract_enum_values(source, runtime_class),

          # Union members (if applicable)
          union_members: extract_union_members(source, runtime_class),

          # Metrics
          field_count: count_fields(source, runtime_class),
          argument_count: count_arguments(source, runtime_class),
          loc: source.lines.count { |l| l.strip.length.positive? && !l.strip.start_with?('#') }
        }
      end

      # Detect what kind of GraphQL construct this is
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Symbol]
      def detect_graphql_kind(source, runtime_class)
        if runtime_class
          return :schema if defined?(GraphQL::Schema) && runtime_class < GraphQL::Schema
          return :enum if defined?(GraphQL::Schema::Enum) && runtime_class < GraphQL::Schema::Enum
          return :union if defined?(GraphQL::Schema::Union) && runtime_class < GraphQL::Schema::Union
          return :input_object if defined?(GraphQL::Schema::InputObject) && runtime_class < GraphQL::Schema::InputObject
          return :scalar if defined?(GraphQL::Schema::Scalar) && runtime_class < GraphQL::Schema::Scalar
          return :mutation if defined?(GraphQL::Schema::Mutation) && runtime_class < GraphQL::Schema::Mutation
          return :resolver if defined?(GraphQL::Schema::Resolver) && runtime_class < GraphQL::Schema::Resolver
          return :interface if runtime_class.is_a?(Module) && defined?(GraphQL::Schema::Interface) && runtime_class.respond_to?(:included_modules) && runtime_class.included_modules.any? do |m|
            m.name&.include?('GraphQL::Schema::Interface')
          end
          return :object if defined?(GraphQL::Schema::Object) && runtime_class < GraphQL::Schema::Object
        end

        # Fall back to source analysis
        return :schema if source.match?(/<\s*(?:::)?GraphQL::Schema\b(?!::)/)
        return :enum if source.match?(/< .*Enum\b/) || source.match?(/value\s+["']/)
        return :union if source.match?(/< .*Union\b/) || source.match?(/possible_types\s/)
        return :input_object if source.match?(/< .*InputObject\b/)
        return :scalar if source.match?(/< .*Scalar\b/)
        return :mutation if source.match?(/< .*(Mutation|RelayClassicMutation)\b/)
        return :resolver if source.match?(/< .*Resolver\b/)
        return :interface if source.match?(/include GraphQL::Schema::Interface/)

        :object
      end

      # Extract field definitions from source and/or runtime
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Array<Hash>]
      def extract_fields(source, runtime_class)
        # Prefer runtime introspection when available
        if runtime_class.respond_to?(:fields) && runtime_class.fields.any?
          return extract_fields_from_runtime(runtime_class)
        end

        extract_fields_from_source(source)
      end

      # Extract fields via runtime reflection
      #
      # @param runtime_class [Class]
      # @return [Array<Hash>]
      def extract_fields_from_runtime(runtime_class)
        runtime_class.fields.map do |name, field|
          field_hash = {
            name: name,
            type: field.type.to_type_signature,
            description: field.description,
            null: field_nullable?(field)
          }

          # Arguments on the field
          if field.respond_to?(:arguments) && field.arguments.any?
            field_hash[:arguments] = field.arguments.map do |arg_name, arg|
              {
                name: arg_name,
                type: arg.type.to_type_signature,
                required: arg.type.non_null?,
                description: arg.description
              }
            end
          end

          # Resolver class
          field_hash[:resolver_class] = field.resolver.name if field.respond_to?(:resolver) && field.resolver

          # Complexity
          field_hash[:complexity] = field.complexity if field.respond_to?(:complexity) && field.complexity

          field_hash
        end
      rescue StandardError
        extract_fields_from_source('')
      end

      # Check if a field is nullable
      #
      # @param field [GraphQL::Schema::Field]
      # @return [Boolean]
      def field_nullable?(field)
        !field.type.non_null?
      rescue StandardError
        true
      end

      # Extract fields by parsing source text
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_fields_from_source(source)
        fields = []

        # Match: field :name, Type, null: true/false, description: "..."
        source.scan(/field\s+:(\w+)(?:,\s*(\S+?))?(?:,\s*(.+?))?(?:\s+do\s*$|\s*$)/m) do |name, type, rest|
          field_hash = { name: name, type: type }

          if rest
            field_hash[:null] = !rest.include?('null: false')
            desc_match = rest.match(/description:\s*["']([^"']+)["']/)
            field_hash[:description] = desc_match[1] if desc_match
            resolver_match = rest.match(/resolver:\s*([\w:]+)/)
            field_hash[:resolver_class] = resolver_match[1] if resolver_match
          end

          fields << field_hash
        end

        fields
      end

      # Extract argument definitions
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Array<Hash>]
      def extract_arguments(source, runtime_class)
        # Prefer runtime introspection
        if runtime_class.respond_to?(:arguments) && runtime_class.arguments.any?
          return extract_arguments_from_runtime(runtime_class)
        end

        extract_arguments_from_source(source)
      end

      # Extract arguments via runtime reflection
      #
      # @param runtime_class [Class]
      # @return [Array<Hash>]
      def extract_arguments_from_runtime(runtime_class)
        runtime_class.arguments.map do |name, arg|
          {
            name: name,
            type: arg.type.to_type_signature,
            required: arg.type.non_null?,
            description: arg.description
          }
        end
      rescue StandardError
        []
      end

      # Extract arguments by parsing source text
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_arguments_from_source(source)
        args = []

        source.scan(/argument\s+:(\w+)(?:,\s*(\S+?))?(?:,\s*(.+?))?$/) do |name, type, rest|
          arg_hash = { name: name, type: type }

          if rest
            arg_hash[:required] = rest.include?('required: true')
            desc_match = rest.match(/description:\s*["']([^"']+)["']/)
            arg_hash[:description] = desc_match[1] if desc_match
          end

          args << arg_hash
        end

        args
      end

      # Extract interface implementations
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Array<String>]
      def extract_interfaces(source, runtime_class)
        if runtime_class.respond_to?(:interfaces) && runtime_class.interfaces.any?
          return runtime_class.interfaces.filter_map(&:name)
        end

        source.scan(/implements\s+([\w:]+)/).flatten
      rescue StandardError
        source.scan(/implements\s+([\w:]+)/).flatten
      end

      # Extract connection type references
      #
      # @param source [String]
      # @return [Array<String>]
      def extract_connections(source)
        # field :items, Types::ItemType.connection_type
        connections = source.scan(/([\w:]+)\.connection_type/).flatten

        # connection_type_class ConnectionType
        source.scan(/connection_type_class\s+([\w:]+)/).flatten.each do |type|
          connections << type
        end

        connections.uniq
      end

      # Extract references to standalone resolver classes
      #
      # @param source [String]
      # @return [Array<String>]
      def extract_resolver_references(source)
        source.scan(/resolver:\s*([\w:]+)/).flatten.uniq
      end

      # Detect authorization patterns
      #
      # @param source [String]
      # @return [Hash]
      def extract_authorization(source)
        auth = {}

        auth[:has_authorized_method] = source.match?(/def\s+(?:self\.)?authorized\?/) || false
        auth[:pundit] = source.match?(/PolicyFinder|policy_class|authorize!?\s/) || false
        auth[:cancan] = source.match?(/can\?|authorize!\s|CanCan|Ability/) || false
        auth[:custom_guard] = source.match?(/def\s+(?:self\.)?(?:visible\?|scope_items|ready\?)/) || false

        auth
      end

      # Extract field complexity settings
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_complexity(source)
        complexities = []

        # `[^\n]*?` keeps the field name and its `complexity:` on one
        # declaration line. With `.*?` under /m the match crossed
        # declarations, so a field with no complexity absorbed the *next*
        # field's — and the real owner lost it, because `scan` resumes after
        # the match (EXTB-8). The lambda value may still span lines.
        source.scan(/field\s+:(\w+)[^\n]*?complexity:\s*(\d+|->.*?(?:end|\}))/m) do |name, value|
          complexities << { field: name, complexity: value.strip }
        end

        # Max complexity on schema level. `match`, not `match?` — the latter
        # never populates `$~`/`Regexp.last_match`, so the capture always
        # read back as 0 (or a stale match from elsewhere in the method).
        if (schema_match = source.match(/max_complexity\s+(\d+)/))
          complexities << { field: :schema, complexity: schema_match[1].to_i }
        end

        complexities
      end

      # Extract enum values (for enum types)
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Array<Hash>]
      def extract_enum_values(source, runtime_class)
        if runtime_class.respond_to?(:values) && runtime_class.values.is_a?(Hash)
          return runtime_class.values.map do |name, value_obj|
            {
              name: name,
              value: value_obj.respond_to?(:value) ? value_obj.value : name,
              description: value_obj.respond_to?(:description) ? value_obj.description : nil
            }
          end
        end

        # Parse from source
        values = []
        source.scan(/value\s+["'](\w+)["'](?:.*?description:\s*["']([^"']+)["'])?/) do |name, desc|
          values << { name: name, description: desc }
        end

        values
      rescue StandardError
        []
      end

      # Extract union member types
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Array<String>]
      def extract_union_members(source, runtime_class)
        if runtime_class.respond_to?(:possible_types) && runtime_class.possible_types.any?
          return runtime_class.possible_types.filter_map(&:name)
        end

        source.scan(/possible_types\s+(.+)$/).flatten.flat_map do |types_str|
          types_str.scan(/([\w:]+)/).flatten
        end
      rescue StandardError
        []
      end

      # ──────────────────────────────────────────────────────────────────────
      # Field Counting Helpers
      # ──────────────────────────────────────────────────────────────────────

      # Count fields from runtime or source
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Integer]
      def count_fields(source, runtime_class)
        if runtime_class.respond_to?(:fields)
          runtime_class.fields.size
        else
          source.scan(/^\s*field\s+:/).size
        end
      rescue StandardError
        source.scan(/^\s*field\s+:/).size
      end

      # Count arguments from runtime or source
      #
      # @param source [String]
      # @param runtime_class [Class, nil]
      # @return [Integer]
      def count_arguments(source, runtime_class)
        if runtime_class.respond_to?(:arguments)
          runtime_class.arguments.size
        else
          source.scan(/^\s*argument\s+:/).size
        end
      rescue StandardError
        source.scan(/^\s*argument\s+:/).size
      end

      # ──────────────────────────────────────────────────────────────────────
      # Dependency Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract all dependencies from source text
      #
      # Uses pattern scanning (not AR descendant iteration) to avoid O(n^2).
      #
      # @param source [String]
      # @return [Array<Hash>]
      def extract_dependencies(source, identifier = nil)
        # Other GraphQL type references (Types::*), excluding self-references
        deps = source.scan(/Types::\w+/).uniq.filter_map do |type_ref|
          next if type_ref == identifier

          { type: :graphql_type, target: type_ref, via: :type_reference }
        end

        # Model references: scan for capitalized constants that look like model names.
        # GraphQL uses its own pattern (not ModelNameCache) to avoid O(n^2).
        source.scan(/\b([A-Z][a-z]\w*)\.(?:find|where|find_by|create|new|first|last|all|count|exists\?|destroy|update|pluck|select|order|limit|includes|joins|preload|eager_load)\b/).flatten.uniq.each do |model_ref|
          deps << { type: :model, target: model_ref, via: :code_reference }
        end

        # The per-constant follow-up check used to run one full-source scan
        # for every unique capitalized constant (audit P9c). One combined
        # scan collects the constants that are actually followed by a model
        # call; only the exact word at a position can match (each candidate
        # is a maximal word in this source and `\.` must immediately follow),
        # so the collected set is identical. Candidate order drives emission
        # below, unchanged.
        candidates = source.scan(/\b([A-Z][a-z][a-zA-Z]*)\b/).flatten.uniq
        model_callers = if candidates.empty?
                          {}
                        else
                          source.scan(
                            /\b(#{candidates.map { |c| Regexp.escape(c) }.join('|')})\.(?:find|where|find_by|create|new|first|last|all)\b/
                          ).flatten.to_h { |const| [const, true] }
                        end

        candidates.each do |const_ref|
          if const_ref.match?(/\A(Types|Mutations|Resolvers|GraphQL|Base|String|Integer|Float|Boolean|Array|Hash|Set|Struct|Module|Class|Object|ID|Int|ISO8601)\z/)
            next
          end
          next if deps.any? { |d| d[:target] == const_ref }

          deps << { type: :model, target: const_ref, via: :code_reference } if model_callers.key?(const_ref)
        end

        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_job_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))

        # Resolver dependencies (standalone resolver classes referenced in fields)
        source.scan(/resolver:\s*([\w:]+)/).flatten.uniq.each do |resolver|
          deps << { type: :graphql_resolver, target: resolver, via: :field_resolver }
        end

        consolidate_dependencies(deps)
      end

      # ──────────────────────────────────────────────────────────────────────
      # Chunking
      # ──────────────────────────────────────────────────────────────────────

      # Build semantic chunks for large GraphQL types
      #
      # @param unit [ExtractedUnit]
      # @param runtime_class [Class, nil]
      # @return [Array<Hash>]
      def build_chunks(unit, _runtime_class)
        chunks = []

        # Summary chunk: overview with field list
        chunks << build_summary_chunk(unit)

        # Field-group chunks for types with many fields
        fields = unit.metadata[:fields] || []
        if fields.size > 10
          fields.each_slice(10).with_index do |field_group, idx|
            chunks << build_field_group_chunk(unit, field_group, idx)
          end
        end

        # Arguments chunk for mutations/resolvers
        arguments = unit.metadata[:arguments] || []
        chunks << build_arguments_chunk(unit, arguments) if arguments.any?

        chunks
      end

      # Build a summary chunk with high-level type information
      #
      # @param unit [ExtractedUnit]
      # @return [Hash]
      def build_summary_chunk(unit)
        meta = unit.metadata
        fields = meta[:fields] || []
        field_names = fields.map { |f| f[:name] }.compact

        interfaces = meta[:interfaces] || []
        auth = meta[:authorization] || {}

        auth_summary = []
        auth_summary << 'authorized?' if auth[:has_authorized_method]
        auth_summary << 'pundit' if auth[:pundit]
        auth_summary << 'cancan' if auth[:cancan]

        {
          chunk_type: :summary,
          identifier: "#{unit.identifier}:summary",
          content: <<~SUMMARY,
            # #{unit.identifier} - #{format_type_label(unit.type)} Summary

            Kind: #{meta[:graphql_kind]}
            Parent: #{meta[:parent_class] || 'unknown'}
            Fields: #{field_names.join(', ').presence || 'none'}
            Interfaces: #{interfaces.join(', ').presence || 'none'}
            Authorization: #{auth_summary.join(', ').presence || 'none'}
          SUMMARY
          metadata: { parent: unit.identifier, purpose: :overview }
        }
      end

      # Build a chunk for a group of fields
      #
      # @param unit [ExtractedUnit]
      # @param field_group [Array<Hash>]
      # @param group_index [Integer]
      # @return [Hash]
      def build_field_group_chunk(unit, field_group, group_index)
        lines = field_group.map do |f|
          parts = ["field :#{f[:name]}"]
          parts << f[:type] if f[:type]
          parts << "(#{f[:description]})" if f[:description]
          parts.join(', ')
        end

        {
          chunk_type: :fields,
          identifier: "#{unit.identifier}:fields_#{group_index}",
          content: <<~FIELDS,
            # #{unit.identifier} - Fields (group #{group_index})

            #{lines.join("\n")}
          FIELDS
          metadata: { parent: unit.identifier, purpose: :fields, group_index: group_index }
        }
      end

      # Build a chunk for arguments
      #
      # @param unit [ExtractedUnit]
      # @param arguments [Array<Hash>]
      # @return [Hash]
      def build_arguments_chunk(unit, arguments)
        lines = arguments.map do |a|
          parts = ["argument :#{a[:name]}"]
          parts << a[:type] if a[:type]
          parts << 'required' if a[:required]
          parts << "(#{a[:description]})" if a[:description]
          parts.join(', ')
        end

        {
          chunk_type: :arguments,
          identifier: "#{unit.identifier}:arguments",
          content: <<~ARGS,
            # #{unit.identifier} - Arguments

            #{lines.join("\n")}
          ARGS
          metadata: { parent: unit.identifier, purpose: :arguments }
        }
      end
    end
  end
end
