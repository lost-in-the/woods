# frozen_string_literal: true

require_relative '../source_inputs/consumer_errors'
require_relative '../graphql_document_paths'
require_relative 'graphql_operation_schema'

module Woods
  module Extractors
    # GraphQLOperationExtractor indexes client-side GraphQL operation documents.
    #
    # `.graphql` / `.gql` files under `config.graphql_document_paths` declare
    # which server fields the application's own clients depend on. Each named
    # operation and each fragment becomes one `graphql_operation` unit, with
    # edges to the server-side resolver, mutation and type units it selects, so
    # `dependents` of a mutation lists the client documents that call it.
    #
    # Documents are parsed with graphql-ruby's own parser. The gem is optional:
    # when it is not loaded the family is skipped with a logged note. Selections
    # resolve against the booted schema ({GraphQLOperationSchema}), so there is
    # no per-file entry point; incremental runs replace the family wholesale.
    #
    # @example
    #   units = GraphQLOperationExtractor.new.extract_all
    #   list = units.find { |u| u.identifier == "gql:WidgetList" }
    #   list.metadata[:field_selections] # => ["Query.widgets", "Widget.id"]
    #
    class GraphQLOperationExtractor
      IDENTIFIER_PREFIX = 'gql:'

      # One operation or fragment, before it becomes a unit.
      Definition = Struct.new(:relative_path, :node, :kind, :name, :source, :identifier, keyword_init: true)

      EDGE_ORDER = %i[root_field type_reference fragment_spread].freeze

      class << self
        # @return [Boolean] whether graphql-ruby's parser is loaded
        def parser_available?
          return false unless defined?(GraphQL) && GraphQL.respond_to?(:parse)

          defined?(GraphQL::Language::Nodes::OperationDefinition) ? true : false
        end

        # Why a document under the configured roots yields no unit.
        #
        # Shared with {SkippedFiles}, so the report and the extractor give one
        # verdict per document.
        #
        # @param absolute_path [String]
        # @return [String, nil] +graphql_unavailable+, +schema_definitions+,
        #   +parse_error+, or nil when the document holds only operations and fragments
        def document_skip_reason(absolute_path)
          return 'graphql_unavailable' unless parser_available?

          nodes = GraphQL.parse(File.read(absolute_path, encoding: Encoding::UTF_8)).definitions
          nodes.all? { |node| executable?(node) } ? nil : 'schema_definitions'
        rescue StandardError
          'parse_error'
        end

        # @param node [GraphQL::Language::Nodes::AbstractNode]
        # @return [Boolean] an operation or fragment definition
        def executable?(node)
          node.is_a?(GraphQL::Language::Nodes::OperationDefinition) ||
            node.is_a?(GraphQL::Language::Nodes::FragmentDefinition)
        end
      end

      def initialize
        @root = Rails.root.to_s
      end

      # Extract every operation and fragment under the configured roots.
      #
      # @return [Array<ExtractedUnit>] units in document path, then line, order
      def extract_all
        paths = GraphQLDocumentPaths.under(@root)
        return [] if paths.empty?

        unless self.class.parser_available?
          Rails.logger.info('[Woods] Skipping GraphQL operation documents: the graphql gem is not loaded')
          return []
        end

        definitions = paths.flat_map { |relative_path| definitions_in(relative_path) }
        assign_identifiers(definitions)
        schema = GraphQLOperationSchema.new
        fragments = definitions.select { |definition| definition.kind == 'fragment' }.group_by(&:name)
        definitions.map { |definition| build_unit(definition, schema, fragments) }
      end

      private

      # ──────────────────────────────────────────────────────────────────────
      # Documents
      # ──────────────────────────────────────────────────────────────────────

      # @return [Array<Definition>] empty for a schema dump or an unparseable file
      def definitions_in(relative_path)
        source = File.read(File.join(@root, relative_path), encoding: Encoding::UTF_8)
        nodes = GraphQL.parse(source).definitions
        unless nodes.all? { |node| self.class.executable?(node) }
          Rails.logger.info("[Woods] Skipping #{relative_path}: schema definitions, not an operation document")
          return []
        end

        slices = source_slices(source, nodes)
        nodes.each_with_index.map { |node, index| definition_for(relative_path, node, slices[index]) }
      rescue GraphQL::ParseError => e
        Rails.logger.warn("[Woods] Skipping #{relative_path}: not a parseable GraphQL document (#{e.message})")
        []
      rescue StandardError => e
        SourceInputs::ConsumerErrors.log(self, "Failed to extract GraphQL document #{relative_path}: #{e.message}")
        []
      end

      def definition_for(relative_path, node, source)
        fragment = node.is_a?(GraphQL::Language::Nodes::FragmentDefinition)
        Definition.new(relative_path: relative_path, node: node, source: source, name: node.name,
                       kind: fragment ? 'fragment' : (node.operation_type || 'query'))
      end

      # The original text of each definition: from its first line up to the next
      # definition, minus trailing blank and comment lines (those lead into the
      # next one). Definitions sharing a line fall back to the printed form.
      def source_slices(source, nodes)
        lines = source.lines
        nodes.each_with_index.map do |node, index|
          following = nodes[index + 1]
          next node.to_query_string if shares_line?(node, nodes[index - 1], index) || following&.line == node.line

          slice = lines[(node.line - 1)...(following ? following.line - 1 : lines.size)] || []
          last = slice.rindex { |line| !trailing_filler?(line) } || 0
          "#{slice[0..last].join.rstrip}\n"
        end
      end

      def shares_line?(node, previous, index)
        index.positive? && previous.line == node.line
      end

      def trailing_filler?(line)
        stripped = line.strip
        stripped.empty? || stripped.start_with?('#')
      end

      # ──────────────────────────────────────────────────────────────────────
      # Identifiers
      # ──────────────────────────────────────────────────────────────────────

      # `gql:<Name>`, or `gql:<path>` for an anonymous operation. Names are
      # global to a client, but nothing enforces that across documents: a later
      # definition of a taken name is qualified by its path, then by its line.
      def assign_identifiers(definitions)
        taken = {}
        definitions.each do |definition|
          path = definition.relative_path
          candidates = definition.name ? [definition.name, "#{definition.name}@#{path}"] : [path]
          candidates << "#{candidates.last}:#{definition.node.line}"
          candidates << "#{candidates.last}:#{definition.node.col}"
          label = candidates.find { |candidate| !taken.key?(candidate) } || candidates.last
          taken[label] = true
          definition.identifier = "#{IDENTIFIER_PREFIX}#{label}"
        end
      end

      # ──────────────────────────────────────────────────────────────────────
      # Units
      # ──────────────────────────────────────────────────────────────────────

      def build_unit(definition, schema, fragments)
        resolution = schema.resolve(definition.node)
        spread_targets, unknown_fragments = fragment_targets(definition, resolution.fragment_spreads, fragments)

        unit = ExtractedUnit.new(type: :graphql_operation, identifier: definition.identifier,
                                 file_path: File.join(@root, definition.relative_path))
        unit.namespace = nil
        unit.source_code = definition.source
        unit.metadata = metadata_for(definition, resolution, unknown_fragments)
        unit.dependencies = dependencies_for(resolution, spread_targets)
        unit
      end

      def metadata_for(definition, resolution, unknown_fragments)
        node = definition.node
        {
          kind: definition.kind,
          operation_name: definition.name,
          document_path: definition.relative_path,
          line: node.line,
          variables: variables_of(node),
          type_condition: (node.type.name if definition.kind == 'fragment'),
          top_level_fields: resolution.top_level_fields,
          field_selections: resolution.field_selections,
          fragment_spreads: resolution.fragment_spreads,
          schema: resolution.schema_name,
          unknown_fields: resolution.unknown_fields,
          unknown_types: resolution.unknown_types,
          unknown_fragments: unknown_fragments
        }
      end

      # @return [Array<Hash>] name, type and printed default, in declaration order
      def variables_of(node)
        return [] unless node.respond_to?(:variables)

        node.variables.map do |variable|
          default = variable.default_value.nil? ? nil : variable.to_query_string.split(' = ', 2).last
          { name: variable.name, type: variable.type.to_query_string, default: default }
        end
      end

      # A spread names a fragment in its own document first. Otherwise every
      # fragment of that name is a candidate: the client's bundler decides which
      # one, and the index cannot.
      #
      # @return [Array(Array<String>, Array<String>)] fragment identifiers, unresolved names
      def fragment_targets(definition, spreads, fragments)
        unknown = []
        targets = spreads.flat_map do |name|
          candidates = fragments.fetch(name, [])
          local = candidates.select { |fragment| fragment.relative_path == definition.relative_path }
          chosen = (local.empty? ? candidates : local).map(&:identifier) - [definition.identifier]
          unknown << name if candidates.empty?
          chosen
        end
        [targets.uniq.sort, unknown.sort]
      end

      def dependencies_for(resolution, spread_targets)
        edges = resolution.root_targets.map { |type, target| { type: type.to_sym, target: target, via: :root_field } }
        edges += resolution.type_targets.map { |type, target| { type: type.to_sym, target: target, via: :type_reference } }
        edges += spread_targets.map { |target| { type: :graphql_operation, target: target, via: :fragment_spread } }
        edges.sort_by { |edge| [EDGE_ORDER.index(edge[:via]), edge[:target]] }
             .uniq { |edge| [edge[:type], edge[:target]] }
      end
    end
  end
end
