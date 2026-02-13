# frozen_string_literal: true

require 'set'

module CodebaseIndex
  # GraphAnalyzer computes structural properties of the dependency graph.
  #
  # Given a {DependencyGraph}, it identifies architectural patterns like orphaned
  # units, circular dependencies, hub nodes, and bridge nodes. These metrics help
  # surface dead code, architectural bottlenecks, and high-risk change targets.
  #
  # Inspired by FlowMapper's Comparator pattern — takes a graph, produces a
  # structural report without mutating anything.
  #
  # @example Basic usage
  #   graph = CodebaseIndex::DependencyGraph.new
  #   # ... register units ...
  #   analyzer = CodebaseIndex::GraphAnalyzer.new(graph)
  #   report = analyzer.analyze
  #   report[:cycles]  # => [["A", "B", "A"], ...]
  #   report[:hubs]    # => [{ identifier: "User", type: :model, ... }, ...]
  #
  class GraphAnalyzer
    # Types that are naturally root nodes and should not be flagged as orphans.
    # Framework and gem sources are consumed but never referenced by application code
    # in the dependency graph's reverse index.
    EXCLUDED_ORPHAN_TYPES = %i[rails_source gem_source].freeze

    # @param dependency_graph [DependencyGraph] The graph to analyze
    def initialize(dependency_graph)
      @graph = dependency_graph
    end

    # ══════════════════════════════════════════════════════════════════════
    # Public Analysis Methods
    # ══════════════════════════════════════════════════════════════════════

    # Units with no dependents (nothing references them).
    #
    # These are potential dead code or entry points. Framework and gem sources
    # are excluded since they are naturally unreferenced in the reverse index.
    #
    # @return [Array<String>] Identifiers of orphaned units
    def orphans
      @orphans ||= begin
        nodes = graph_nodes
        nodes.each_with_object([]) do |(identifier, meta), result|
          next if EXCLUDED_ORPHAN_TYPES.include?(meta[:type])

          dependents = @graph.dependents_of(identifier)
          result << identifier if dependents.empty?
        end
      end
    end

    # Units with no dependencies (leaf nodes).
    #
    # These are self-contained units that don't reference anything else —
    # typically utility classes, value objects, or standalone services.
    #
    # @return [Array<String>] Identifiers of dead-end units
    def dead_ends
      @dead_ends ||= begin
        nodes = graph_nodes
        nodes.each_with_object([]) do |(identifier, _meta), result|
          dependencies = @graph.dependencies_of(identifier)
          result << identifier if dependencies.empty?
        end
      end
    end

    # Units with the highest number of dependents (architectural hotspots).
    #
    # A high dependent count means many other units reference this one. Changes
    # to hub nodes have the widest blast radius.
    #
    # @param limit [Integer] Maximum number of hubs to return
    # @return [Array<Hash>] Sorted by dependent_count descending.
    #   Each hash contains :identifier, :type, :dependent_count, :dependents
    def hubs(limit: 20)
      nodes = graph_nodes

      nodes.map do |identifier, meta|
        dependents = @graph.dependents_of(identifier)
        {
          identifier: identifier,
          type: meta[:type],
          dependent_count: dependents.size,
          dependents: dependents
        }
      end
           .sort_by { |h| -h[:dependent_count] }
           .first(limit)
    end

    # Detect circular dependency chains in the graph.
    #
    # Uses iterative DFS with a three-color marking scheme (white/gray/black).
    # When a gray (in-progress) node is revisited, a cycle has been found.
    # The cycle path is extracted from the recursion stack.
    #
    # @return [Array<Array<String>>] Each element is a cycle represented as
    #   an ordered array of identifiers, ending with the repeated node.
    #   For example: ["A", "B", "C", "A"]
    def cycles
      @cycles ||= detect_cycles
    end

    # Units that bridge different types in the graph.
    #
    # Computes a simplified betweenness centrality metric — for each unit, we
    # estimate how many shortest paths between sampled node pairs pass through
    # it. High-scoring nodes are architectural bottlenecks whose failure or
    # change would disrupt many cross-type communication paths.
    #
    # For performance, samples a subset of node pairs rather than computing
    # all-pairs shortest paths.
    #
    # @param limit [Integer] Maximum number of bridges to return
    # @param sample_size [Integer] Number of node pairs to sample for estimation
    # @return [Array<Hash>] Sorted by score descending.
    #   Each hash contains :identifier, :type, :score
    def bridges(limit: 20, sample_size: 200)
      nodes = graph_nodes
      return [] if nodes.size < 3

      node_ids = nodes.keys
      scores = Hash.new(0)

      # Sample random pairs of nodes for shortest-path computation.
      # Use a deterministic seed so results are reproducible for the same graph.
      rng = Random.new(node_ids.size)
      pairs = generate_sample_pairs(node_ids, sample_size, rng)

      pairs.each do |source, target|
        path = bfs_shortest_path(source, target)
        next unless path && path.size > 2

        # Credit intermediate nodes (exclude source and target)
        path[1..-2].each do |intermediate|
          scores[intermediate] += 1
        end
      end

      scores
        .sort_by { |_id, score| -score }
        .first(limit)
        .map do |identifier, score|
          meta = nodes[identifier] || {}
          {
            identifier: identifier,
            type: meta[:type],
            score: score
          }
        end
    end

    # Full analysis report combining all structural metrics.
    #
    # @return [Hash] Complete analysis with :orphans, :dead_ends, :hubs,
    #   :cycles, :bridges, and :stats
    def analyze
      computed_orphans = orphans
      computed_dead_ends = dead_ends
      computed_hubs = hubs
      computed_cycles = cycles
      computed_bridges = bridges(limit: 10)

      {
        orphans: computed_orphans,
        dead_ends: computed_dead_ends,
        hubs: computed_hubs,
        cycles: computed_cycles,
        bridges: computed_bridges,
        stats: {
          orphan_count: computed_orphans.size,
          dead_end_count: computed_dead_ends.size,
          hub_count: computed_hubs.size,
          cycle_count: computed_cycles.size
        }
      }
    end

    private

    # ──────────────────────────────────────────────────────────────────────
    # Graph Accessors
    # ──────────────────────────────────────────────────────────────────────

    # Cache the full graph serialization once, avoiding repeated to_h calls.
    #
    # @return [Hash] Full graph data
    def graph_data
      @graph_data ||= @graph.to_h
    end

    # Access graph nodes from cached graph data.
    #
    # @return [Hash] identifier => { type:, file_path:, namespace: }
    def graph_nodes
      @graph_nodes ||= graph_data[:nodes]
    end

    # Access graph forward edges from cached graph data.
    #
    # @return [Hash] identifier => [dependency identifiers]
    def graph_edges
      @graph_edges ||= graph_data[:edges]
    end

    # ──────────────────────────────────────────────────────────────────────
    # Cycle Detection (Three-Color DFS)
    # ──────────────────────────────────────────────────────────────────────

    # Detects all cycles using iterative DFS with white/gray/black coloring.
    #
    # - White (unvisited): node has not been seen
    # - Gray (in-progress): node is on the current DFS stack
    # - Black (complete): node and all its descendants are fully explored
    #
    # When we encounter a gray node, we've found a cycle. We extract it
    # from the path stack.
    #
    # @return [Array<Array<String>>] Detected cycles
    def detect_cycles
      nodes = graph_nodes
      return [] if nodes.empty?

      white = 0
      gray  = 1
      black = 2

      color = Hash.new(white)
      parent = {}
      found_cycles = []
      seen_cycle_signatures = Set.new

      nodes.each_key do |start_node|
        next unless color[start_node] == white

        # Iterative DFS using an explicit stack.
        # Each entry is [node, :enter] or [node, :exit].
        stack = [[start_node, :enter]]

        # Track the current DFS path for cycle extraction.
        path = []

        while stack.any?
          node, action = stack.pop

          if action == :exit
            color[node] = black
            path.pop
            next
          end

          # :enter action
          next unless color[node] == white

          color[node] = gray
          path.push(node)
          stack.push([node, :exit])

          neighbors = @graph.dependencies_of(node)
          neighbors.each do |neighbor|
            case color[neighbor]
            when white
              parent[neighbor] = node
              stack.push([neighbor, :enter])
            when gray
              # Found a cycle — extract it from the path
              cycle = extract_cycle_from_path(path, neighbor)
              if cycle
                sig = normalize_cycle_signature(cycle)
                unless seen_cycle_signatures.include?(sig)
                  seen_cycle_signatures.add(sig)
                  found_cycles << cycle
                end
              end
            end
            # black nodes are fully explored, skip them
          end
        end
      end

      found_cycles
    end

    # Extracts a cycle from the current DFS path when a back-edge to
    # +cycle_start+ is found.
    #
    # @param path [Array<String>] Current DFS path
    # @param cycle_start [String] The node that closes the cycle
    # @return [Array<String>, nil] The cycle path ending with cycle_start repeated,
    #   or nil if cycle_start is not in the path
    def extract_cycle_from_path(path, cycle_start)
      start_index = path.index(cycle_start)
      return nil unless start_index

      path[start_index..] + [cycle_start]
    end

    # Normalize a cycle so that duplicate rotations are treated as the same cycle.
    # For example, [A, B, C, A] and [B, C, A, B] are the same cycle.
    #
    # @param cycle [Array<String>] Cycle path with repeated last element
    # @return [String] Canonical string representation
    def normalize_cycle_signature(cycle)
      # Remove the trailing repeated element to get the raw loop
      loop_nodes = cycle[0..-2]
      return loop_nodes.join('->') if loop_nodes.empty?

      # Rotate so the lexicographically smallest element is first
      min_index = loop_nodes.each_with_index.min_by { |node, _i| node }.last
      rotated = loop_nodes.rotate(min_index)
      rotated.join('->')
    end

    # ──────────────────────────────────────────────────────────────────────
    # Bridge Detection (Sampled Betweenness Centrality)
    # ──────────────────────────────────────────────────────────────────────

    # Generate random pairs of distinct nodes for betweenness sampling.
    #
    # @param node_ids [Array<String>] All node identifiers
    # @param sample_size [Integer] Number of pairs to generate
    # @param rng [Random] Random number generator for reproducibility
    # @return [Array<Array<String>>] Pairs of [source, target]
    def generate_sample_pairs(node_ids, sample_size, rng)
      max_possible = node_ids.size * (node_ids.size - 1)
      effective_sample = [sample_size, max_possible].min

      pairs = Set.new
      attempts = 0
      max_attempts = effective_sample * 3

      while pairs.size < effective_sample && attempts < max_attempts
        a = node_ids[rng.rand(node_ids.size)]
        b = node_ids[rng.rand(node_ids.size)]
        pairs.add([a, b]) unless a == b
        attempts += 1
      end

      pairs.to_a
    end

    # BFS shortest path between two nodes, following forward edges.
    #
    # @param source [String] Starting node identifier
    # @param target [String] Target node identifier
    # @return [Array<String>, nil] Shortest path or nil if unreachable
    def bfs_shortest_path(source, target)
      return [source] if source == target

      visited = Set.new([source])
      queue = [[source, [source]]]

      while queue.any?
        current, path = queue.shift

        @graph.dependencies_of(current).each do |neighbor|
          next if visited.include?(neighbor)

          new_path = path + [neighbor]
          return new_path if neighbor == target

          visited.add(neighbor)
          queue.push([neighbor, new_path])
        end
      end

      nil
    end
  end
end
