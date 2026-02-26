# frozen_string_literal: true

require 'set'
require 'json'

module CodebaseIndex
  # DependencyGraph tracks relationships between code units for:
  # 1. Understanding what depends on what
  # 2. Computing "blast radius" for incremental re-indexing
  # 3. Enabling graph-based retrieval queries
  #
  # The graph is bidirectional - we track both what a unit depends on
  # and what depends on that unit (reverse edges).
  #
  # @example Building and querying the graph
  #   graph = DependencyGraph.new
  #   graph.register(user_model_unit)
  #   graph.register(user_service_unit)
  #
  #   # Find everything affected by a change to user.rb
  #   affected = graph.affected_by(["app/models/user.rb"])
  #
  class DependencyGraph
    def initialize
      @nodes = {}      # identifier => { type:, file_path: }
      @edges = {}      # identifier => [dependency identifiers]
      @reverse = {}    # identifier => [dependent identifiers]
      @file_map = {}   # file_path => identifier
      @type_index = {} # type => [identifiers]
    end

    # Register a unit in the graph
    #
    # @param unit [ExtractedUnit] The unit to register
    def register(unit)
      @nodes[unit.identifier] = {
        type: unit.type,
        file_path: unit.file_path,
        namespace: unit.namespace
      }

      @edges[unit.identifier] = unit.dependencies.map { |d| d[:target] }
      @file_map[unit.file_path] = unit.identifier if unit.file_path

      # Type index for filtering
      @type_index[unit.type] ||= []
      @type_index[unit.type] << unit.identifier unless @type_index[unit.type].include?(unit.identifier)

      # Build reverse edges
      unit.dependencies.each do |dep|
        @reverse[dep[:target]] ||= []
        @reverse[dep[:target]] << unit.identifier unless @reverse[dep[:target]].include?(unit.identifier)
      end
    end

    # Find all units affected by changes to given files
    # Uses BFS to find transitive dependents
    #
    # @param changed_files [Array<String>] List of changed file paths
    # @param max_depth [Integer] Maximum traversal depth (nil for unlimited)
    # @return [Array<String>] List of affected unit identifiers
    def affected_by(changed_files, max_depth: nil)
      directly_changed = changed_files.filter_map { |f| @file_map[f] }

      affected = Set.new(directly_changed)
      queue = directly_changed.map { |id| [id, 0] } # [identifier, depth]

      while queue.any?
        current, depth = queue.shift
        next if max_depth && depth >= max_depth

        dependents = @reverse[current] || []

        dependents.each do |dep|
          unless affected.include?(dep)
            affected.add(dep)
            queue.push([dep, depth + 1])
          end
        end
      end

      affected.to_a
    end

    # Check if a node exists in the graph by exact identifier.
    #
    # @param identifier [String] Unit identifier to check
    # @return [Boolean] true if the node exists
    def node_exists?(identifier)
      @nodes.key?(identifier)
    end

    # Find a node by suffix matching (e.g., "Update" matches "Order::Update").
    #
    # When multiple nodes share the same suffix, the first match wins.
    # Suffix matching requires a "::" separator — bare identifiers (no namespace)
    # are not matched by this method; use {#node_exists?} for exact lookups.
    #
    # @param suffix [String] The suffix to match against
    # @return [String, nil] The first matching identifier, or nil
    def find_node_by_suffix(suffix)
      target_suffix = "::#{suffix}"
      @nodes.keys.find { |id| id.end_with?(target_suffix) }
    end

    # Get direct dependencies of a unit
    #
    # @param identifier [String] Unit identifier
    # @return [Array<String>] List of dependency identifiers
    def dependencies_of(identifier)
      @edges[identifier] || []
    end

    # Get direct dependents of a unit (what depends on it)
    #
    # @param identifier [String] Unit identifier
    # @return [Array<String>] List of dependent identifiers
    def dependents_of(identifier)
      @reverse[identifier] || []
    end

    # Get all units of a specific type
    #
    # @param type [Symbol] Unit type (:model, :controller, etc.)
    # @return [Array<String>] List of unit identifiers
    def units_of_type(type)
      @type_index[type] || []
    end

    # Compute PageRank scores for all nodes
    #
    # Uses the reverse edges (dependents) as the link structure: a node
    # with many dependents gets a higher score. This matches Aider's insight
    # that structural importance correlates with retrieval relevance.
    #
    # @param damping [Float] Damping factor (default: 0.85)
    # @param iterations [Integer] Number of iterations (default: 20)
    # @return [Hash<String, Float>] Identifier => PageRank score
    def pagerank(damping: 0.85, iterations: 20)
      n = @nodes.size
      return {} if n.zero?

      base_score = 1.0 / n
      scores = @nodes.keys.to_h { |id| [id, base_score] }

      iterations.times do
        # Collect rank from dangling nodes (no outgoing edges) and redistribute
        dangling_sum = @nodes.keys.sum do |id|
          @edges[id].nil? || @edges[id].empty? ? scores[id] : 0.0
        end

        new_scores = {}

        @nodes.each_key do |id|
          # Sum contributions from nodes that depend on this one
          incoming = @reverse[id] || []
          rank_sum = incoming.sum do |src|
            out_degree = (@edges[src] || []).size
            out_degree.positive? ? scores[src] / out_degree : 0.0
          end

          new_scores[id] = ((1.0 - damping) / n) + (damping * (rank_sum + (dangling_sum / n)))
        end

        scores = new_scores
      end

      scores
    end

    # Serialize graph for persistence
    #
    # @return [Hash] Complete graph data
    def to_h
      {
        nodes: @nodes,
        edges: @edges,
        reverse: @reverse,
        file_map: @file_map,
        type_index: @type_index,
        stats: {
          node_count: @nodes.size,
          edge_count: @edges.values.sum(&:size),
          types: @type_index.transform_values(&:size)
        }
      }
    end

    # Load graph from persisted data
    #
    # After JSON round-trip all keys become strings. This method normalizes
    # them back to the expected types: node values use symbol keys (:type,
    # :file_path, :namespace), and type_index uses symbol keys for types.
    #
    # @param data [Hash] Previously serialized graph data
    # @return [DependencyGraph] Restored graph
    def self.from_h(data)
      graph = new

      raw_nodes = data[:nodes] || data['nodes'] || {}
      graph.instance_variable_set(:@nodes, raw_nodes.transform_values { |v| symbolize_node(v) })

      graph.instance_variable_set(:@edges, data[:edges] || data['edges'] || {})
      graph.instance_variable_set(:@reverse, data[:reverse] || data['reverse'] || {})
      graph.instance_variable_set(:@file_map, data[:file_map] || data['file_map'] || {})

      raw_type_index = data[:type_index] || data['type_index'] || {}
      graph.instance_variable_set(:@type_index, raw_type_index.transform_keys(&:to_sym))

      graph
    end

    # Normalize a node hash to use symbol keys
    #
    # @param node [Hash] Node data with string or symbol keys
    # @return [Hash] Node data with symbol keys
    def self.symbolize_node(node)
      return node unless node.is_a?(Hash)

      {
        type: (node[:type] || node['type'])&.to_sym,
        file_path: node[:file_path] || node['file_path'],
        namespace: node[:namespace] || node['namespace']
      }
    end
  end
end
