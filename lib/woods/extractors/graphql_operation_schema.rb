# frozen_string_literal: true

require 'set'
require_relative 'graphql_extractor'
require_relative 'shared_utility_methods'

module Woods
  module Extractors
    # Resolves the selections of a parsed GraphQL operation or fragment against
    # the booted application schema.
    #
    # Reads schema metadata only (`get_field`, `Field#type`, `Field#resolver`);
    # no field, resolver or `resolve_type` body runs. An edge target is named
    # only when {GraphQLExtractor} publishes a unit for that class, so schema
    # drift and gem-defined types never become dangling edges.
    #
    # @example
    #   schema = GraphQLOperationSchema.new
    #   resolution = schema.resolve(document.definitions.first)
    #   resolution.field_selections # => ["Query.widgets", "Widget.id"]
    #
    class GraphQLOperationSchema
      include SharedUtilityMethods

      # What one definition selects, against one schema.
      Resolution = Struct.new(:schema_name, :top_level_fields, :field_selections, :fragment_spreads,
                              :unknown_fields, :unknown_types, :root_targets, :type_targets, keyword_init: true) do
        # @return [Integer] how much of the definition this schema could not resolve
        def unknown_count
          unknown_fields.size + unknown_types.size
        end
      end

      def initialize
        @graphql = GraphQLExtractor.new
        @runtime = Set.new.compare_by_identity.merge(@graphql.discoverable_classes)
        @schemas = @runtime.select { |klass| klass.is_a?(Class) && klass < GraphQL::Schema }.sort_by(&:name)
        @unit_types = {}.compare_by_identity
        @graphql_root = "#{Rails.root.join(GraphQLExtractor::GRAPHQL_DIRECTORY)}/"
      end

      # Resolve against the schema that explains the most of the definition.
      # Ties go to the first schema by name, so the choice is stable.
      #
      # @param node [GraphQL::Language::Nodes::OperationDefinition, GraphQL::Language::Nodes::FragmentDefinition]
      # @return [Resolution]
      def resolve(node)
        return walk(node, nil) if @schemas.empty?

        best = nil
        @schemas.each do |schema|
          candidate = walk(node, schema)
          best = candidate if best.nil? || candidate.unknown_count < best.unknown_count
          break if best.unknown_count.zero?
        end
        best
      end

      private

      # Iterative: document depth is bounded by the parser, not by this stack.
      def walk(node, schema)
        state = { top: [], fields: Set.new, spreads: Set.new, unknown_fields: Set.new, unknown_types: Set.new,
                  roots: Set.new, types: Set.new.compare_by_identity }
        root_label, root_type = root_of(node, schema, state)
        stack = [[node.selections, root_type, root_label]]
        until stack.empty?
          selections, type, label = stack.pop
          selections.each { |selection| visit(selection, type, label, schema, state, stack) }
        end
        resolution(schema, state)
      end

      # @return [Array(String, Module)] the label an unresolved root field is
      #   reported under (operations only), and the type selections start from
      def root_of(node, schema, state)
        if node.is_a?(GraphQL::Language::Nodes::FragmentDefinition)
          type = named_type(schema, node.type.name)
          state[:unknown_types] << node.type.name if schema && type.nil?
          state[:types] << type if type
          [nil, type]
        else
          operation = node.operation_type || 'query'
          [operation.capitalize, schema&.public_send(operation)]
        end
      end

      def visit(selection, type, root_label, schema, state, stack)
        case selection
        when GraphQL::Language::Nodes::Field
          visit_field(selection, type, root_label, schema, state, stack)
        when GraphQL::Language::Nodes::InlineFragment
          narrowed = selection.type ? named_type(schema, selection.type.name) : type
          state[:unknown_types] << selection.type.name if schema && selection.type && narrowed.nil?
          state[:types] << narrowed if selection.type && narrowed
          stack << [selection.selections, narrowed, nil]
        when GraphQL::Language::Nodes::FragmentSpread
          state[:spreads] << selection.name
        end
      end

      def visit_field(selection, type, root_label, schema, state, stack)
        name = selection.name
        return if name.start_with?('__')

        state[:top] << name if root_label
        child = nil
        field = field_on(type, name)
        if field
          state[:fields] << "#{type.graphql_name}.#{name}"
          state[:roots] << root_target(field) if root_label
          child = return_type(field)
          state[:types] << child if child
        elsif type
          state[:unknown_fields] << "#{type.graphql_name}.#{name}"
        elsif schema && root_label
          state[:unknown_fields] << "#{root_label}.#{name}"
        end
        stack << [selection.selections, child, nil] unless selection.selections.empty?
      end

      def resolution(schema, state)
        Resolution.new(
          schema_name: schema&.name,
          top_level_fields: state[:top].uniq,
          field_selections: state[:fields].sort,
          fragment_spreads: state[:spreads].sort,
          unknown_fields: state[:unknown_fields].sort,
          unknown_types: state[:unknown_types].sort,
          root_targets: state[:roots].to_a.compact.sort,
          type_targets: state[:types].filter_map { |type| unit_target(type) }.sort
        )
      end

      # The unit a root field resolves through: its resolver or mutation class,
      # else the type that defines it.
      #
      # @return [Array(String, String), nil] unit type and identifier
      def root_target(field)
        resolver = field.resolver if field.respond_to?(:resolver)
        (resolver && unit_target(resolver)) || unit_target(field.owner)
      end

      # @return [Array(String, String), nil] unit type and identifier
      def unit_target(klass)
        type = unit_type_for(klass)
        [type.to_s, klass.name] if type
      end

      def unit_type_for(klass)
        return @unit_types[klass] if @unit_types.key?(klass)

        @unit_types[klass] = published_unit_type(klass)
      end

      # Mirrors what {GraphQLExtractor#extract_all} publishes: every runtime
      # class it admits, plus the governed first class of an app/graphql file.
      def published_unit_type(klass)
        name = klass.respond_to?(:name) ? klass.name : nil
        return nil if name.nil? || name.start_with?('GraphQL::')
        return @graphql.runtime_unit_type(klass) if @runtime.include?(klass)

        path = resolve_source_location(klass, app_root: Rails.root.to_s, fallback: nil)
        return nil unless path && File.expand_path(path).start_with?(@graphql_root)

        unit = @graphql.extract_graphql_file(path)
        unit.type if unit && unit.identifier == name
      rescue StandardError
        nil
      end

      def field_on(type, name)
        return nil unless type.respond_to?(:kind) && type.kind.fields?

        type.get_field(name)
      rescue StandardError
        nil
      end

      # @return [Module, nil] the composite type a field returns
      def return_type(field)
        type = field.type.unwrap
        type if type.respond_to?(:kind) && type.kind.composite?
      rescue StandardError
        nil
      end

      def named_type(schema, name)
        schema&.get_type(name)
      rescue StandardError
        nil
      end
    end
  end
end
