# frozen_string_literal: true

require 'set'

module Woods
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
  #   graph = Woods::DependencyGraph.new
  #   # ... register units ...
  #   analyzer = Woods::GraphAnalyzer.new(graph)
  #   report = analyzer.analyze
  #   report[:cycles]  # => [["A", "B", "A"], ...]
  #   report[:hubs]    # => [{ identifier: "User", type: :model, ... }, ...]
  #
  class GraphAnalyzer
    # Types that are naturally root nodes and should not be flagged as orphans.
    # Framework and gem sources are consumed but never referenced by application code
    # in the dependency graph's reverse index.
    EXCLUDED_ORPHAN_TYPES = %i[rails_source gem_source].freeze

    # How many rounds {#assign_orphaned_units} runs before it stops pulling
    # unnamespaced units into clusters through other unnamespaced units. The
    # loop already stops early on the first round that assigns nothing; this
    # bounds the pathological case (a long chain of unnamespaced units, where
    # each round advances the frontier by one) so clustering stays linear-ish
    # on large graphs.
    ORPHAN_ASSIGNMENT_ROUNDS = 10

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
        end.sort
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
        end.sort
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

      identifiers_with_dependents = nodes.map do |identifier, meta|
        dependents = @graph.dependents_of(identifier)
        {
          identifier: identifier,
          type: meta[:type],
          dependent_count: dependents.size,
          # Sorted for the same reason the outer list tie-breaks on identifier:
          # `dependents_of` returns graph-registration order, so an incremental
          # run that appended a dependent would publish a different hub entry
          # for an identical graph.
          dependents: dependents.sort
        }
      end
      # Tie-break on identifier. Without it, which of the (often many) nodes
      # sharing a dependent count land inside the top-N depends on graph
      # insertion order, so two extractions of the same tree could publish
      # different hub lists (#164) — incremental runs append new nodes at the
      # end where a full extraction interleaves them by extractor.
      identifiers_with_dependents
        .sort_by { |h| [-h[:dependent_count], h[:identifier].to_s] }
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

      # Sorted, not insertion-ordered: the seeded sample indexes into this
      # list, so leaving it in graph order would make the sampled pairs (and
      # therefore the bridge scores) depend on the order units happened to be
      # registered in rather than on the graph's content (#164).
      node_ids = nodes.keys.sort
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

    # Group units into semantic domains using namespace prefixes and graph connectivity.
    #
    # Strategy:
    # 1. Seed clusters from top-level namespace prefixes (e.g., ShippingProfile::*, Order::*)
    # 2. Assign unnamespaced units to their most-connected cluster
    # 3. Merge small clusters (< min_size) into their most-connected neighbor
    # 4. For each cluster, identify the hub (highest PageRank) and entry points
    # 5. Compute boundary edges between clusters
    #
    # @param min_size [Integer] Minimum units per cluster before merging (default: 3)
    # @param types [Array<String>, nil] Filter to these unit types (default: all)
    # @return [Array<Hash>] Clusters sorted by member count descending.
    #   Each hash: { name:, hub:, members:, member_count:, entry_points:, boundary_edges:, types: }
    def domain_clusters(min_size: 3, types: nil)
      nodes = graph_nodes
      return [] if nodes.empty?

      # Filter by types if specified
      filtered_ids = if types
                       type_set = types.map(&:to_s)
                       nodes.select { |_, meta| type_set.include?(meta[:type].to_s) }.keys
                     else
                       nodes.keys
                     end

      return [] if filtered_ids.empty?

      # Step 1: Seed clusters from namespace prefixes
      clusters = seed_namespace_clusters(filtered_ids, nodes)

      # Step 2: Assign unnamespaced/root units to most-connected cluster
      assign_orphaned_units(clusters, filtered_ids, nodes)

      # Step 3: Merge small clusters
      merge_small_clusters(clusters, min_size)

      # Step 4: Enrich each cluster with hub, entry points, boundary edges
      pagerank_scores = @graph.pagerank
      enrich_clusters(clusters, nodes, pagerank_scores)

      # Sort by member count descending
      clusters.values
              .select { |c| c[:members].any? }
              .sort_by { |c| [-c[:member_count], c[:name].to_s] }
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
    # Domain Cluster Helpers
    # ──────────────────────────────────────────────────────────────────────

    # Extract the top-level namespace prefix for clustering.
    # "ShippingProfile::Setting" => "ShippingProfile"
    # "Order::Transactions::Refund" => "Order"
    # "Account" => nil (no namespace)
    def cluster_prefix(identifier)
      parts = identifier.to_s.split('::')
      parts.size > 1 ? parts.first : nil
    end

    # Seed initial clusters from namespace prefixes.
    def seed_namespace_clusters(filtered_ids, _nodes)
      clusters = {}

      filtered_ids.each do |id|
        prefix = cluster_prefix(id)
        next unless prefix

        clusters[prefix] ||= { name: prefix, members: [], member_set: Set.new }
        clusters[prefix][:members] << id
        clusters[prefix][:member_set].add(id)
      end

      clusters
    end

    # Assign units with no namespace prefix to their most-connected cluster.
    #
    # Order-free (EXTB-7). Each round scores *every* still-unassigned unit
    # against one membership snapshot taken before the round, then applies all
    # of that round's assignments at once. Assigning inside the scoring loop —
    # as this did — let a unit whose only connection is another unnamespaced
    # unit join a cluster or not depending on which of the two the graph
    # happened to enumerate first, i.e. on registration order, which differs
    # between a full and an incremental run.
    #
    # Rounds are bounded: each one either assigns at least one unit or ends the
    # loop, and {ORPHAN_ASSIGNMENT_ROUNDS} caps how far a chain of unnamespaced
    # units can pull its successors in. Units past that depth stay unassigned —
    # deterministically, which is the property that matters here.
    def assign_orphaned_units(clusters, filtered_ids, _nodes)
      return if clusters.empty?

      pending = filtered_ids.select { |id| cluster_prefix(id).nil? }.sort

      ORPHAN_ASSIGNMENT_ROUNDS.times do
        break if pending.empty?

        membership = clusters.transform_values { |cluster| cluster[:member_set] }.freeze
        assignments = pending.filter_map do |id|
          best_cluster = find_most_connected_cluster(id, clusters.keys, membership)
          [id, best_cluster] if best_cluster
        end
        break if assignments.empty?

        assignments.each do |id, name|
          clusters[name][:members] << id
          clusters[name][:member_set].add(id)
        end
        pending -= assignments.map(&:first)
      end
    end

    # Find which cluster a unit has the most connections to.
    #
    # @param identifier [String]
    # @param cluster_names [Array<String>]
    # @param membership [Hash{String => Set<String>}] name => members, read as
    #   of the start of the assignment round (see {#assign_orphaned_units})
    # @return [String, nil]
    def find_most_connected_cluster(identifier, cluster_names, membership)
      connections = Hash.new(0)

      # Check forward edges (dependencies)
      @graph.dependencies_of(identifier).each do |dep|
        cluster_names.each do |name|
          connections[name] += 1 if membership[name].include?(dep)
        end
      end

      # Check reverse edges (dependents)
      @graph.dependents_of(identifier).each do |dep|
        cluster_names.each do |name|
          connections[name] += 1 if membership[name].include?(dep)
        end
      end

      return nil if connections.empty?

      # Tie-break on cluster name. `max_by` alone returns whichever equal-count
      # cluster the hash happened to enumerate first, which is registration
      # order — the one determinism hole left in this class.
      connections.max_by { |name, count| [count, name] }.first
    end

    # Merge clusters smaller than min_size into their most-connected neighbor.
    def merge_small_clusters(clusters, min_size)
      loop do
        small = clusters.select { |_, c| c[:members].size < min_size }
        break if small.empty?

        # Merge the smallest cluster first
        name, cluster = small.min_by { |cluster_name, c| [c[:members].size, cluster_name] }

        # Find which other cluster this one connects to most
        target = find_merge_target(cluster, clusters, name)

        break unless target

        clusters[target][:members].concat(cluster[:members])
        cluster[:members].each { |id| clusters[target][:member_set].add(id) }
        clusters.delete(name)
      end
    end

    # Find the best cluster to merge into (most cross-cluster edges).
    def find_merge_target(cluster, all_clusters, exclude_name)
      connections = Hash.new(0)

      cluster[:members].each do |id|
        (@graph.dependencies_of(id) + @graph.dependents_of(id)).each do |connected|
          all_clusters.each do |name, other|
            next if name == exclude_name

            connections[name] += 1 if other[:member_set].include?(connected)
          end
        end
      end

      return nil if connections.empty?

      # Tie-break on cluster name. `max_by` alone returns whichever equal-count
      # cluster the hash happened to enumerate first, which is registration
      # order — the one determinism hole left in this class.
      connections.max_by { |name, count| [count, name] }.first
    end

    # Enrich clusters with hub, entry points, boundary edges, and type breakdown.
    def enrich_clusters(clusters, nodes, pagerank_scores)
      clusters.each_value do |cluster|
        # Sorted, like orphans/dead_ends/hubs. Members accumulate in graph
        # registration order, and an incremental run appends where a full
        # extraction interleaves by extractor — so an unsorted list publishes
        # a different cluster for an identical graph. Everything derived below
        # (entry points, boundary edges) inherits this order too.
        members = cluster[:members].sort
        cluster[:members] = members
        member_set = cluster[:member_set]

        # Hub: highest PageRank within the cluster
        hub_id = members.max_by { |id| [pagerank_scores[id] || 0, id] }
        cluster[:hub] = hub_id

        # Entry points: controllers and GraphQL resolvers in the cluster's dependents
        entry_types = %w[controller graphql_resolver graphql_mutation graphql_query]
        entry_points = Set.new
        members.each do |id|
          @graph.dependents_of(id).each do |dep|
            meta = nodes[dep]
            entry_points.add(dep) if meta && entry_types.include?(meta[:type].to_s)
          end
        end
        cluster[:entry_points] = entry_points.to_a.sort

        # Boundary edges: connections that cross cluster boundaries
        boundary = []
        members.each do |id|
          @graph.dependencies_of(id).each do |dep|
            next if member_set.include?(dep)

            dep_meta = nodes[dep]
            next unless dep_meta

            boundary << { from: id, to: dep, via: 'dependency' }
          end

          @graph.dependents_of(id).each do |dep|
            next if member_set.include?(dep)

            dep_meta = nodes[dep]
            next unless dep_meta

            boundary << { from: dep, to: id, via: 'dependent' }
          end
        end
        # Deduplicate and limit boundary edges
        cluster[:boundary_edges] = boundary.uniq { |e| [e[:from], e[:to]] }
                                           .sort_by { |e| [e[:from].to_s, e[:to].to_s] }.first(20)

        # Type breakdown
        type_counts = members.each_with_object(Hash.new(0)) do |id, counts|
          meta = nodes[id]
          counts[meta[:type].to_s] += 1 if meta
        end
        cluster[:types] = type_counts

        # Final shape
        cluster[:member_count] = members.size
        cluster.delete(:member_set) # Internal tracking, not part of output
      end
    end

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

      nodes.keys.sort.each do |start_node|
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

          # Not sorted, deliberately: this list is the unit's own declared
          # dependency order, which is identical in a full and an incremental
          # run, so sorting it would change nothing any test can observe.
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

      # Deterministic without a final sort: the DFS starts from a sorted
      # node list, so cycles are discovered in the same order every run.
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
