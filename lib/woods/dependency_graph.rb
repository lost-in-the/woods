# frozen_string_literal: true

require 'set'
require 'json'

module Woods
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
      @edges = {}      # identifier => [{ target:, via: }]
      @reverse = {}    # identifier => Set of dependent identifiers
      @reverse_via = {} # [target, via] => Set of dependent identifiers
      @file_map = {}   # file_path => identifier
      @type_index = {} # type => Set of identifiers
      @to_h = nil
    end

    # Register a unit in the graph.
    #
    # Re-registering an identifier (incremental extraction registers into a
    # graph loaded from disk) first removes the previous registration's
    # reverse edges, file-map entry, and type-index entry — otherwise stale
    # dependents accumulate across incremental runs and get persisted back
    # to dependency_graph.json.
    #
    # @param unit [ExtractedUnit] The unit to register
    def register(unit)
      @to_h = nil

      unregister(unit.identifier) if @nodes.key?(unit.identifier)

      @nodes[unit.identifier] = {
        type: unit.type,
        file_path: unit.file_path,
        namespace: unit.namespace
      }

      @edges[unit.identifier] = unit.dependencies.map { |d| { target: d[:target], via: d[:via] } }
      @file_map[unit.file_path] = unit.identifier if unit.file_path

      # Type index for filtering (Set-based for O(1) insert)
      (@type_index[unit.type] ||= Set.new).add(unit.identifier)

      # Build reverse edges (Set-based for O(1) insert)
      unit.dependencies.each do |dep|
        (@reverse[dep[:target]] ||= Set.new).add(unit.identifier)
        (@reverse_via[[dep[:target], dep[:via]]] ||= Set.new).add(unit.identifier)
      end
    end

    # Remove an identifier's registration side effects: its contribution to
    # the reverse indexes (derived from its recorded forward edges), its
    # file-map entry, and its type-index entry. Forward node/edge data is
    # overwritten by the caller (register), so it is not cleared here.
    #
    # @param identifier [String] Previously-registered unit identifier
    # @return [void]
    def unregister(identifier)
      (@edges[identifier] || []).each do |edge|
        if (set = @reverse[edge[:target]])
          set.delete(identifier)
          @reverse.delete(edge[:target]) if set.empty?
        end

        via_key = [edge[:target], edge[:via]]
        next unless (set = @reverse_via[via_key])

        set.delete(identifier)
        @reverse_via.delete(via_key) if set.empty?
      end

      old_node = @nodes[identifier]
      return unless old_node

      old_path = old_node[:file_path]
      @file_map.delete(old_path) if old_path && @file_map[old_path] == identifier
      @type_index[old_node[:type]]&.delete(identifier)
    end

    # Fully remove a unit from the graph: its node, its forward edges, and
    # all registration side effects (reverse indexes, file-map entry, type
    # index) via {#unregister}. Forward edges other units hold toward the
    # removed identifier are left in place — they describe those units'
    # source and are refreshed when their owners re-register.
    #
    # @param identifier [String] Unit identifier to remove (no-op if absent)
    # @return [void]
    def remove(identifier)
      return unless @nodes.key?(identifier)

      @to_h = nil
      unregister(identifier)
      @nodes.delete(identifier)
      @edges.delete(identifier)
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

    # Check whether any registered unit claims the given file path.
    #
    # Paths are compared exactly as stored at registration time — the
    # persisted file_map holds absolute paths (full extraction registers
    # units before Phase 4.5 path normalization).
    #
    # @param file_path [String] Absolute file path
    # @return [Boolean] true if a unit is registered for this file
    def tracks_file?(file_path)
      @file_map.key?(file_path)
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
    # @param via [Symbol, Array<Symbol>, nil] Filter by relationship type(s)
    # @return [Array<String>] List of dependency identifiers
    def dependencies_of(identifier, via: nil)
      edges = @edges[identifier] || []
      if via
        via_set = Array(via)
        edges = edges.select { |e| via_set.include?(e[:via]) }
      end
      edges.map { |e| e[:target] }
    end

    # Get direct dependents of a unit (what depends on it)
    #
    # @param identifier [String] Unit identifier
    # @param via [Symbol, Array<Symbol>, nil] Filter by relationship type(s)
    # @return [Array<String>] List of dependent identifiers
    def dependents_of(identifier, via: nil)
      return @reverse.fetch(identifier, Set.new).to_a unless via

      Array(via).each_with_object(Set.new) do |v, result|
        @reverse_via.fetch([identifier, v], Set.new).each { |dep| result.add(dep) }
      end.to_a
    end

    # Get all units of a specific type
    #
    # @param type [Symbol] Unit type (:model, :controller, etc.)
    # @return [Array<String>] List of unit identifiers
    def units_of_type(type)
      @type_index.fetch(type, Set.new).to_a
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

      node_ids = @nodes.keys
      base_score = 1.0 / n
      scores = node_ids.to_h { |id| [id, base_score] }

      iterations.times do
        # Collect rank from dangling nodes (no outgoing edges) and redistribute
        dangling_sum = node_ids.sum do |id|
          @edges[id].nil? || @edges[id].empty? ? scores[id] : 0.0
        end

        new_scores = {}

        node_ids.each do |id|
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

    # Serialize graph for persistence. Memoized — cache is invalidated on register.
    # Returns a dup so callers can't pollute the cached hash.
    #
    # @return [Hash] Complete graph data
    def to_h
      @to_h ||= {
        nodes: @nodes,
        edges: @edges,
        reverse: @reverse.transform_values(&:to_a),
        file_map: @file_map,
        type_index: @type_index.transform_values(&:to_a),
        stats: {
          node_count: @nodes.size,
          edge_count: @edges.values.sum(&:size),
          types: @type_index.transform_values(&:size)
        }
      }
      @to_h.dup
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

      raw_edges = data[:edges] || data['edges'] || {}
      graph.instance_variable_set(:@edges, raw_edges.transform_values { |edges| normalize_edges(edges) })

      raw_reverse = data[:reverse] || data['reverse'] || {}
      graph.instance_variable_set(:@reverse, raw_reverse.transform_values { |v| v.is_a?(Set) ? v : Set.new(v) })

      graph.instance_variable_set(:@file_map, data[:file_map] || data['file_map'] || {})

      raw_type_index = data[:type_index] || data['type_index'] || {}
      graph.instance_variable_set(:@type_index, raw_type_index.transform_keys(&:to_sym).transform_values do |v|
        v.is_a?(Set) ? v : Set.new(v)
      end)

      # Rebuild reverse_via index from edges
      reverse_via = {}
      graph.instance_variable_get(:@edges).each do |source_id, edges|
        edges.each do |edge|
          (reverse_via[[edge[:target], edge[:via]]] ||= Set.new).add(source_id)
        end
      end
      graph.instance_variable_set(:@reverse_via, reverse_via)

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

    # Normalize edge data from either old format (bare strings) or new format (hashes).
    #
    # ROUND-TRIP INVARIANT (do not break when refactoring):
    #   DependencyGraph#to_h -> JSON.generate -> JSON.parse -> DependencyGraph.from_h
    # must always yield the same in-memory shape. The two normalizers that
    # sit at either end of this round trip are INTENTIONALLY SEPARATE — do
    # not merge them:
    #
    # - This method ({.normalize_edges}) runs on Ruby objects. It produces
    #   `{ target:, via: }` with SYMBOL keys because consumers
    #   ({DependencyGraph#dependencies_of}, {GraphAnalyzer}) key on symbols.
    # - {Woods::MCP::IndexReader.normalize_all_edges} runs on parsed JSON,
    #   producing `{ 'target' => ..., 'via' => ... }` with STRING keys,
    #   because the MCP tools serialize straight through to the client and
    #   symbol keys would become `:target` on the wire.
    #
    # This method also accepts OLD-format bare-string edges so graphs
    # serialized before the `{target, via}` migration still load without
    # explicit data conversion.
    #
    # @param edges [Array] Edge entries — either strings or hashes
    # @return [Array<Hash>] Normalized edges with :target and :via keys
    def self.normalize_edges(edges)
      return [] unless edges.is_a?(Array)

      edges.map do |edge|
        if edge.is_a?(String)
          { target: edge, via: nil }
        elsif edge.is_a?(Hash)
          { target: edge[:target] || edge['target'], via: (edge[:via] || edge['via'])&.to_sym }
        else
          { target: edge.to_s, via: nil }
        end
      end
    end
  end
end
