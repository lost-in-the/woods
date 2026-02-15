# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'shared_dependency_scanner'

module CodebaseIndex
  module Extractors
    # GraphQLExtractor handles graphql-ruby type and mutation extraction.
    #
    # GraphQL schemas are rich in structure — types, fields, arguments,
    # resolvers, and mutations form a typed API layer over the domain.
    # We extract these with runtime introspection when available (via
    # `GraphQL::Schema.types`) and fall back to file-based discovery
    # when the schema isn't fully loadable.
    #
    # We extract:
    # - Object types, input types, enum types, interface types, union types, scalar types
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

      # Standard directory for graphql-ruby applications
      GRAPHQL_DIRECTORY = 'app/graphql'

      # Token threshold for chunking large types
      CHUNK_THRESHOLD = 1500

      def initialize
        @graphql_dir = defined?(Rails) ? Rails.root.join(GRAPHQL_DIRECTORY) : nil
        @schema_class = find_schema_class
        @runtime_types = load_runtime_types
      end

      # Extract all GraphQL types, mutations, queries, and resolvers
      #
      # Returns an empty array if graphql-ruby is not installed or
      # no GraphQL files are found.
      #
      # @return [Array<ExtractedUnit>] List of GraphQL units
      def extract_all
        return [] unless graphql_available?

        units = []
        seen_identifiers = Set.new

        # First pass: runtime introspection (most accurate)
        if @runtime_types.any?
          @runtime_types.each_value do |type_class|
            unit = extract_from_runtime_type(type_class)
            next unless unit
            next if seen_identifiers.include?(unit.identifier)

            seen_identifiers << unit.identifier
            units << unit
          end
        end

        # Second pass: file-based discovery (catches everything)
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
        source = File.read(file_path)
        class_name = extract_class_name(file_path, source)

        return nil unless class_name
        return nil unless graphql_class?(source)

        unit_type = classify_unit_type(file_path, source)
        runtime_class = class_name.safe_constantize

        unit = ExtractedUnit.new(
          type: unit_type,
          identifier: class_name,
          file_path: file_path
        )

        unit.namespace = extract_namespace(class_name)
        unit.source_code = build_annotated_source(source, class_name, unit_type, runtime_class)
        unit.metadata = build_metadata(source, class_name, unit_type, runtime_class)
        unit.dependencies = extract_dependencies(source)
        unit.chunks = build_chunks(unit, runtime_class) if unit.needs_chunking?(threshold: CHUNK_THRESHOLD)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract GraphQL file #{file_path}: #{e.message}") if defined?(Rails)
        nil
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Schema and Runtime Discovery
      # ──────────────────────────────────────────────────────────────────────

      # Check if graphql-ruby is available at runtime
      #
      # @return [Boolean]
      def graphql_available?
        return false unless defined?(GraphQL::Schema)
        return false unless @graphql_dir&.directory? || @schema_class

        true
      end

      # Find the application's schema class (descendant of GraphQL::Schema)
      #
      # @return [Class, nil]
      def find_schema_class
        return nil unless defined?(GraphQL::Schema)

        GraphQL::Schema.descendants.find do |klass|
          klass.name && !klass.name.start_with?('GraphQL::')
        end
      rescue StandardError
        nil
      end

      # Load types from the runtime schema for introspection
      #
      # @return [Hash{String => Class}] Map of type name to type class
      def load_runtime_types
        return {} unless @schema_class

        types = {}
        @schema_class.types.each do |name, type_class|
          # Skip built-in introspection types
          next if name.start_with?('__')
          next unless type_class.respond_to?(:name) && type_class.name

          types[name] = type_class
        end

        types
      rescue StandardError
        {}
      end

      # ──────────────────────────────────────────────────────────────────────
      # Runtime Type Extraction
      # ──────────────────────────────────────────────────────────────────────

      # Extract a unit from a runtime-loaded GraphQL type class
      #
      # @param type_class [Class] A graphql-ruby type class
      # @return [ExtractedUnit, nil]
      def extract_from_runtime_type(type_class)
        return nil unless type_class.respond_to?(:name) && type_class.name
        # Skip anonymous or internal graphql-ruby classes
        return nil if type_class.name.start_with?('GraphQL::')

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
        unit.dependencies = extract_dependencies(source)
        unit.chunks = build_chunks(unit, type_class) if unit.needs_chunking?(threshold: CHUNK_THRESHOLD)

        unit
      rescue StandardError => e
        Rails.logger.error("Failed to extract GraphQL type #{type_class.name}: #{e.message}") if defined?(Rails)
        nil
      end

      # Determine the source file for a runtime-loaded class
      #
      # @param klass [Class]
      # @return [String, nil]
      def source_file_for_class(klass)
        # Try method source location first
        if klass.instance_methods(false).any?
          method_name = klass.instance_methods(false).first
          loc = klass.instance_method(method_name).source_location&.first
          return loc if loc
        end

        # Fall back to singleton methods
        if klass.singleton_methods(false).any?
          method_name = klass.singleton_methods(false).first
          loc = klass.method(method_name).source_location&.first
          return loc if loc
        end

        # Fall back to conventional path
        return nil unless defined?(Rails)

        Rails.root.join("#{GRAPHQL_DIRECTORY}/#{klass.name.underscore}.rb").to_s
      rescue StandardError
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
        elsif defined?(GraphQL::Schema::Interface) && type_class.is_a?(Module) && type_class.respond_to?(:fields)
          :graphql_type
        elsif defined?(GraphQL::Schema::InputObject) && type_class < GraphQL::Schema::InputObject
          :graphql_type
        elsif defined?(GraphQL::Schema::Scalar) && type_class < GraphQL::Schema::Scalar
          :graphql_type
        elsif defined?(GraphQL::Schema::Object) && type_class < GraphQL::Schema::Object
          # Check if this is the Query root type
          if @schema_class.respond_to?(:query) && @schema_class.query == type_class
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

        return :graphql_mutation if source.match?(/< (GraphQL::Schema::Mutation|Mutations::Base|BaseMutation)/)

        return :graphql_resolver if source.match?(/< (GraphQL::Schema::Resolver|Resolvers::Base|BaseResolver)/)

        # Query type is usually the root query object
        return :graphql_query if file_path.match?(/query_type\.rb$/) || source.match?(/class QueryType\b/)

        :graphql_type
      end

      # Check if a source file contains a graphql-ruby class
      #
      # @param source [String]
      # @return [Boolean]
      def graphql_class?(source)
        source.match?(/< GraphQL::Schema::(Object|InputObject|Enum|Union|Scalar|Mutation|Resolver|Interface|RelayClassicMutation)/) ||
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
      # @param file_path [String]
      # @param source [String]
      # @return [String, nil]
      def extract_class_name(file_path, source)
        # Build from nested module/class declarations
        modules = source.scan(/^\s*(?:module|class)\s+([\w:]+)/).flatten
        return nil if modules.empty?

        # If first token is a fully-qualified name, use it directly
        return modules.first if modules.first.include?('::')

        # Otherwise join the nesting
        modules.join('::')
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
      def build_metadata(source, _class_name, _unit_type, runtime_class)
        {
          # GraphQL classification
          graphql_kind: detect_graphql_kind(source, runtime_class),
          parent_class: extract_parent_class(source),

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
        return :enum if source.match?(/< .*Enum\b/) || source.match?(/value\s+["']/)
        return :union if source.match?(/< .*Union\b/) || source.match?(/possible_types\s/)
        return :input_object if source.match?(/< .*InputObject\b/)
        return :scalar if source.match?(/< .*Scalar\b/)
        return :mutation if source.match?(/< .*(Mutation|RelayClassicMutation)\b/)
        return :resolver if source.match?(/< .*Resolver\b/)
        return :interface if source.match?(/include GraphQL::Schema::Interface/)

        :object
      end

      # Extract the parent class name from source
      #
      # @param source [String]
      # @return [String, nil]
      def extract_parent_class(source)
        match = source.match(/class\s+\w+\s*<\s*([\w:]+)/)
        match ? match[1] : nil
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
        connections = source.scan(/([\w:]+)\.connection_type/).flatten.map do |type|
          type
        end

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

        source.scan(/field\s+:(\w+).*?complexity:\s*(\d+|->.*?(?:end|\}))/m) do |name, value|
          complexities << { field: name, complexity: value.strip }
        end

        # Max complexity on schema level
        if source.match?(/max_complexity\s+(\d+)/)
          complexities << { field: :schema, complexity: ::Regexp.last_match(1).to_i }
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
      def extract_dependencies(source)
        # Other GraphQL type references (Types::*)
        deps = source.scan(/Types::\w+/).uniq.map do |type_ref|
          { type: :graphql_type, target: type_ref, via: :type_reference }
        end

        # Model references: scan for capitalized constants that look like model names.
        # GraphQL uses its own pattern (not ModelNameCache) to avoid O(n^2).
        source.scan(/\b([A-Z][a-z]\w*)\.(?:find|where|find_by|create|new|first|last|all|count|exists\?|destroy|update|pluck|select|order|limit|includes|joins|preload|eager_load)\b/).flatten.uniq.each do |model_ref|
          deps << { type: :model, target: model_ref, via: :code_reference }
        end

        source.scan(/\b([A-Z][a-z][a-zA-Z]*)\b/).flatten.uniq.each do |const_ref|
          if const_ref.match?(/\A(Types|Mutations|Resolvers|GraphQL|Base|String|Integer|Float|Boolean|Array|Hash|Set|Struct|Module|Class|Object|ID|Int|ISO8601)\z/)
            next
          end
          next if deps.any? { |d| d[:target] == const_ref }

          if source.match?(/\b#{Regexp.escape(const_ref)}\.(?:find|where|find_by|create|new|first|last|all)\b/)
            deps << { type: :model, target: const_ref, via: :code_reference }
          end
        end

        deps.concat(scan_service_dependencies(source))
        deps.concat(scan_job_dependencies(source))
        deps.concat(scan_mailer_dependencies(source))

        # Resolver dependencies (standalone resolver classes referenced in fields)
        source.scan(/resolver:\s*([\w:]+)/).flatten.uniq.each do |resolver|
          deps << { type: :graphql_resolver, target: resolver, via: :field_resolver }
        end

        deps.uniq { |d| [d[:type], d[:target]] }
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
