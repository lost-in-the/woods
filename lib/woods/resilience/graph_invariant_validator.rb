# frozen_string_literal: true

require 'set'
require_relative 'graph_invariant_validator/membership_checks'
require_relative 'graph_invariant_validator/node_checks'
require_relative 'graph_invariant_validator/reverse_relationship_checks'

module Woods
  module Resilience
    # Checks raw published graph data against typed per-directory index entries.
    # It deliberately does not use DependencyGraph.from_h: normalization there
    # can discard malformed records before a validator has seen them.
    #
    # Target identifiers are not necessarily graph nodes (external/unresolved
    # dependencies are valid), and reverse/file/type indexes contain bare names,
    # not typed endpoints. Expected membership is the union over all variants.
    class GraphInvariantValidator
      include MembershipChecks
      include NodeChecks
      include ReverseRelationshipChecks

      def initialize(graph:, index_entries:)
        @graph = graph
        @index_entries = index_entries
      end

      # @return [Array<String>] semantic errors, without changing either input
      def validate
        @errors = []
        return ['dependency_graph.json: expected an object'] unless @graph.is_a?(Hash)

        @typed_nodes = {}
        @primary_types = {}
        @expected_reverse = membership_map
        @expected_reverse_via = Hash.new { |hash, key| hash[key] = [] }
        @expected_files = membership_map
        @expected_types = membership_map
        collect_nodes
        validate_edges
        validate_reverse_relationships
        validate_membership('reverse', @expected_reverse)
        validate_membership('file_map', @expected_files, scalar: true)
        validate_membership('type_index', @expected_types)
        validate_index_agreement
        @errors
      end

      private

      def membership_map
        Hash.new { |hash, key| hash[key] = Set.new }
      end

      def error(label, message)
        @errors << "dependency_graph.json #{label}: #{message}"
      end

      def object_section(name)
        value = @graph[name]
        return value if value.is_a?(Hash)

        error(name, 'expected an object')
        {}
      end

      def name?(value)
        value.is_a?(String) && !value.empty?
      end

      def validate_edges
        edges = object_section('edges')
        @primary_types.each_key do |identifier|
          error('edges', "missing edge list for #{identifier.inspect}") unless edges.key?(identifier)
        end
        edges.each do |identifier, list|
          label = "edges[#{identifier.inspect}]"
          error(label, 'source has no primary node') unless @primary_types.key?(identifier)
          validate_edge_list(identifier, @primary_types[identifier], list, label)
        end
        @variants.each_with_index do |record, index|
          next unless record.is_a?(Hash)

          validate_edge_list(record['identifier'], record['type'], record['edges'], "variants[#{index}].edges")
        end
      end

      def validate_edge_list(source, source_type, list, label)
        unless list.is_a?(Array)
          error(label, 'expected an array')
          return
        end

        list.each_with_index do |edge, index|
          validate_edge(source, source_type, edge, "#{label}[#{index}]")
        end
      end

      def validate_edge(source, source_type, edge, label)
        target = edge.is_a?(Hash) ? edge['target'] : edge
        unless name?(target)
          error(label, 'expected a target identifier or an object with a target identifier')
          return
        end
        validate_edge_attributes(edge, label) if edge.is_a?(Hash)
        @expected_reverse[target].add(source) if name?(source)
        record_reverse_relationship(target, source, source_type, edge)
      end

      def validate_edge_attributes(edge, label)
        %w[via through through_db].each do |key|
          error(label, "#{key} must be a string or null") unless edge[key].nil? || edge[key].is_a?(String)
        end
        return if [nil, true, false].include?(edge['disable_joins'])

        error(label, 'disable_joins must be a boolean or null')
      end
    end
  end
end
