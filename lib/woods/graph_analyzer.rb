# frozen_string_literal: true

require 'digest'
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
    # in the dependency graph's reverse index. Package units (#280) declare
    # boundaries via metadata and `:package_dependency` edges to other
    # packages; nothing points back at a leaf package in the reverse index,
    # so it would otherwise be flagged as dead code it is not.
    EXCLUDED_ORPHAN_TYPES = %i[rails_source gem_source package].freeze

    # How many rounds {#assign_orphaned_units} runs before it stops pulling
    # unnamespaced units into clusters through other unnamespaced units. The
    # loop already stops early on the first round that assigns nothing; this
    # bounds the pathological case (a long chain of unnamespaced units, where
    # each round advances the frontier by one) so clustering stays linear-ish
    # on large graphs.
    ORPHAN_ASSIGNMENT_ROUNDS = 10

    # Edge labels that come from an Active Record association reflection.
    # Only these can cross a database boundary through Rails itself.
    ASSOCIATION_VIAS = %w[belongs_to has_many has_one has_and_belongs_to_many].freeze

    # A dependency must change at least this many times more often than
    # its dependent to be reported by {#volatile_dependencies}.
    DEFAULT_VOLATILE_RATIO = 3.0

    # A dependency with fewer commits in the last year than this is too
    # young to judge; POODR's rule is about things that keep changing, and
    # a class touched four times could be settling down.
    VOLATILE_MIN_COMMITS = 5

    # How many volatile-dependency entries {#analyze} keeps. Published as
    # `stats[:volatile_dependencies_limit]` so a reader of the array alone
    # can tell whether it was truncated (B-182).
    DEFAULT_VOLATILE_LIMIT = 20

    # How many distinct cycles {#detect_cycles} enumerates before it stops.
    # The DFS finds one cycle per back-edge, and a dense graph has tens of
    # thousands of them; nobody reads past the first few hundred, and the
    # per-cycle signature work is what made analysis the fixed floor of every
    # incremental run. `nil` means no cap.
    DEFAULT_CYCLE_LIMIT = 500

    # The longest cycle {#detect_cycles} will record, counted in distinct
    # nodes. A back-edge deep in a DFS closes a cycle as long as the path,
    # which on a large graph is thousands of nodes: unreadable as a report and
    # expensive to canonicalize. `nil` means no cap.
    DEFAULT_CYCLE_MAX_LENGTH = 50

    # @param dependency_graph [DependencyGraph] The graph to analyze
    # @param volatile_ratio [Numeric] see {#volatile_dependencies}
    # @param cycle_limit [Integer, nil] see {DEFAULT_CYCLE_LIMIT}
    # @param cycle_max_length [Integer, nil] see {DEFAULT_CYCLE_MAX_LENGTH}
    def initialize(dependency_graph, volatile_ratio: DEFAULT_VOLATILE_RATIO,
                   cycle_limit: DEFAULT_CYCLE_LIMIT, cycle_max_length: DEFAULT_CYCLE_MAX_LENGTH)
      @graph = dependency_graph
      @volatile_ratio = volatile_ratio.to_f
      @cycle_limit = cycle_limit
      @cycle_max_length = cycle_max_length
      @cycle_limit_reached = false
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

    # Whether {#cycles} is a truncated view of the graph's cycles.
    #
    # True when either cap fired: the count cap stopped enumeration, or at
    # least one cycle was longer than the length cap and was skipped. A reader
    # of the array alone cannot tell, so this is published as
    # `stats[:cycle_limit_reached]` alongside it.
    #
    # @return [Boolean]
    def cycle_limit_reached?
      cycles
      @cycle_limit_reached
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

    # Association and foreign-key edges whose two ends resolve to different
    # databases (#280).
    #
    # Reads only node attributes (`database`, `table`, `foreign_key_tables`)
    # and edge attributes (`through`, `through_db`, `disable_joins`), so an
    # incremental run that loaded the graph from disk computes exactly what
    # a full run does.
    #
    # Scoped to primary nodes: identifiers as registered in {#graph_nodes}.
    # A variant, the non-primary type registered under an identifier that
    # collides across types, is not walked separately. Association edges are
    # read with `type: :model`, so a variant sharing the identifier under a
    # different type cannot contribute a crossing that belongs to it alone.
    #
    # A foreign key never picks a target owner that lives in `from_db`, even
    # when another database also owns the table: an owner in the source
    # database means the key resolves locally, whatever else claims the same
    # table name. Only when every owner sits outside `from_db`, in more than
    # one other database, does the entry come back ambiguous.
    #
    # `kind`:
    # * `join_through_across_databases`: a `has_many :through` where
    #   `disable_joins` is false and `from_db`, `through_db`, and `to_db` are
    #   not all equal (a nil `through_db` falls back to comparing the two
    #   ends). Rails will try to JOIN across connections; this is the
    #   Uchitelle rule.
    # * `association_across_databases`: any other association edge across
    #   databases, including a through with `disable_joins`.
    # * `foreign_key_across_databases`: a database-level foreign key whose
    #   target table's owner (or every owner, when ambiguous) lives in
    #   another database.
    #
    # @return [Array<Hash>] sorted by from, to, via
    def cross_database_edges
      @cross_database_edges ||= begin
        nodes = graph_nodes
        owners = table_owners(nodes)
        entries = nodes.keys.sort.flat_map do |identifier|
          meta = nodes[identifier]
          from_db = meta[:database]
          next [] unless from_db

          association_crossings(identifier, from_db, nodes) +
            foreign_key_crossings(identifier, from_db, meta, owners)
        end
        # Whole-hash dedup, not a `[from, to, via]` key: an ambiguous foreign
        # key entry carries `to: nil` regardless of which table it names, so
        # two distinct ambiguous foreign keys on the same model would
        # otherwise collapse into one.
        entries.uniq.sort_by { |e| [e[:from], e[:to], e[:via]] }
      end
    end

    # Edges that point at something changing much faster than the thing
    # that depends on it: "depend on things that change less often than
    # you do" (POODR ch. 3), made checkable because the graph now carries
    # commit counts (#280).
    #
    # Report only, never a gate: young classes produce false positives, so
    # dependencies with fewer than {VOLATILE_MIN_COMMITS} commits or a
    # `new` change frequency are skipped. Ranked by the dependency's
    # PageRank so the most-depended-on volatile unit comes first. `limit`
    # caps what this method hands back; {#analyze}'s
    # `stats[:volatile_dependency_count]` reports the full qualifying count
    # regardless of `limit`, and `stats[:volatile_dependencies_limit]` reports
    # the cap, so a reader of the array alone can tell it was truncated.
    #
    # @param limit [Integer] maximum entries
    # @return [Array<Hash>] `{ from:, from_type:, to:, to_type:, via:, from_commits:, to_commits:, ratio:, pagerank: }`
    def volatile_dependencies(limit: DEFAULT_VOLATILE_LIMIT)
      all_volatile_dependencies.first(limit)
    end

    # Edges that cross a Packwerk package boundary the source package never
    # declared (#280).
    #
    # Membership comes from the `package` node attribute (Task 8); a
    # declaration comes from a package unit's own `:package_dependency`
    # edges (Task 7). Both are graph-only, so a full and an incremental run
    # compute the same report. Enforcement stays with `packwerk check` /
    # `pks check`; this only makes the undeclared boundary visible.
    #
    # @return [Array<Hash>] `{ from:, from_type:, to:, to_type:, via:, from_package:, to_package: }`, sorted
    def undeclared_package_edges
      @undeclared_package_edges ||= compute_undeclared_package_edges
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
      pagerank_scores = self.pagerank_scores
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
      computed_cross_database = cross_database_edges
      computed_volatile = volatile_dependencies
      computed_undeclared = undeclared_package_edges

      {
        orphans: computed_orphans,
        dead_ends: computed_dead_ends,
        hubs: computed_hubs,
        cycles: computed_cycles,
        bridges: computed_bridges,
        cross_database_edges: computed_cross_database,
        volatile_dependencies: computed_volatile,
        undeclared_package_edges: computed_undeclared,
        stats: {
          orphan_count: computed_orphans.size,
          dead_end_count: computed_dead_ends.size,
          hub_count: computed_hubs.size,
          cycle_count: computed_cycles.size,
          cycle_limit_reached: cycle_limit_reached?,
          cross_database_edge_count: computed_cross_database.size,
          volatile_dependency_count: all_volatile_dependencies.size,
          volatile_dependencies_limit: DEFAULT_VOLATILE_LIMIT,
          undeclared_package_edge_count: computed_undeclared.size
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
    # Cross-database helpers
    # ──────────────────────────────────────────────────────────────────────

    # table name => { database name => sorted identifiers of the model nodes
    # in that database owning it }. Sorted identifier iteration makes a
    # table owned by several nodes in one database resolve to the same
    # first identifier every run; nodes with no table or no database
    # contribute no ownership claim.
    #
    # @param nodes [Hash]
    # @return [Hash{String => Hash{String => Array<String>}}]
    def table_owners(nodes)
      nodes.keys.sort.each_with_object({}) do |identifier, owners|
        node = nodes[identifier]
        table = node[:table]
        database = node[:database]
        next unless table && database

        by_database = (owners[table] ||= {})
        (by_database[database] ||= []) << identifier
      end
    end

    # @return [Array<Hash>] association edges from `identifier` that land in another database
    def association_crossings(identifier, from_db, nodes)
      @graph.edge_records(identifier, type: :model).filter_map do |edge|
        via = edge[:via].to_s
        next unless ASSOCIATION_VIAS.include?(via)

        target = nodes[edge[:target]]
        to_db = target && target[:database]
        through_db = edge[:through] ? edge[:through_db] : nil
        databases = [from_db, to_db, through_db].compact.uniq
        next if databases.size < 2

        disable_joins = edge[:disable_joins] == true
        kind = edge[:through] && !disable_joins ? 'join_through_across_databases' : 'association_across_databases'
        {
          from: identifier, to: edge[:target], via: via, from_db: from_db, to_db: to_db,
          through: edge[:through], through_db: through_db, disable_joins: disable_joins, kind: kind
        }
      end
    end

    # @return [Array<Hash>] foreign keys from `identifier`'s table into a table owned by another database
    def foreign_key_crossings(identifier, from_db, meta, owners)
      Array(meta[:foreign_key_tables]).filter_map do |table|
        foreign_key_crossing(identifier, from_db, table, owners)
      end
    end

    # A single foreign key's crossing entry, or nil when an owner of `table`
    # lives in `from_db` (the key resolves locally regardless of what else
    # claims the table name) or when no node claims the table at all.
    #
    # @return [Hash, nil]
    def foreign_key_crossing(identifier, from_db, table, owners)
      by_database = owners[table]
      return nil if by_database.nil? || by_database.key?(from_db)

      base = {
        from: identifier, via: 'foreign_key', from_db: from_db,
        through: nil, through_db: nil, disable_joins: false, kind: 'foreign_key_across_databases'
      }
      databases = by_database.keys.sort
      if databases.size == 1
        owner_db = databases.first
        base.merge(to: by_database[owner_db].first, to_db: owner_db)
      else
        base.merge(to: nil, to_db: nil, ambiguous_owners: by_database.values.flatten.sort)
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Volatile dependency helpers
    # ──────────────────────────────────────────────────────────────────────

    # PageRank computed once per analyzer instance.
    #
    # @return [Hash{String => Float}]
    def pagerank_scores
      @pagerank_scores ||= @graph.pagerank
    end

    # Every qualifying edge, unranked by {#volatile_dependencies}'s `limit`.
    # {#analyze} needs the full count separately from the persisted top 20.
    #
    # @return [Array<Hash>] sorted by pagerank, ratio, from, to, via
    def all_volatile_dependencies
      @all_volatile_dependencies ||= compute_volatile_dependencies
    end

    # Short-circuits to `[]`, skipping the PageRank computation entirely,
    # when no node carries an Integer `commit_count` (git enrichment never
    # ran): there is nothing to rank.
    #
    # @return [Array<Hash>]
    def compute_volatile_dependencies
      nodes = graph_nodes
      return [] unless nodes.each_value.any? { |meta| meta[:commit_count].is_a?(Integer) }

      scores = pagerank_scores
      entries = nodes.keys.sort.flat_map do |from|
        from_meta = nodes[from]
        from_commits = from_meta[:commit_count]
        next [] unless from_commits.is_a?(Integer)

        @graph.edge_records(from, type: from_meta[:type]).filter_map do |edge|
          volatile_entry(from, from_meta, from_commits, edge, nodes, scores)
        end
      end
      entries.uniq { |e| [e[:from], e[:to], e[:via]] }
             .sort_by { |e| [-e[:pagerank], -e[:ratio], e[:from], e[:to], e[:via]] }
    end

    # @return [Hash, nil] the report entry for one edge, or nil when it is not volatile
    def volatile_entry(from, from_meta, from_commits, edge, nodes, scores)
      to = edge[:target]
      to_meta = nodes[to]
      return nil unless to_meta

      to_commits = to_meta[:commit_count]
      return nil unless to_commits.is_a?(Integer) && to_commits >= VOLATILE_MIN_COMMITS
      return nil if to_meta[:change_frequency] == 'new'

      ratio = to_commits.to_f / [from_commits, 1].max
      return nil if ratio < @volatile_ratio

      {
        from: from, from_type: from_meta[:type], to: to, to_type: to_meta[:type], via: edge[:via].to_s,
        from_commits: from_commits, to_commits: to_commits,
        ratio: ratio.round(2), pagerank: (scores[to] || 0.0).round(4)
      }
    end

    # ──────────────────────────────────────────────────────────────────────
    # Package boundary helpers
    # ──────────────────────────────────────────────────────────────────────

    # Short-circuits to `[]`, skipping declaration lookup entirely, when no
    # node carries a `package` attribute (no package extraction ran).
    #
    # @return [Array<Hash>]
    def compute_undeclared_package_edges
      nodes = graph_nodes
      return [] unless nodes.each_value.any? { |meta| meta.key?(:package) }

      declared = package_declarations(nodes)
      entries = nodes.keys.sort.flat_map do |from|
        meta = nodes[from]
        from_package = meta[:package]
        next [] if from_package.nil? || meta[:type] == :package

        @graph.edge_records(from, type: meta[:type]).filter_map do |edge|
          undeclared_entry(from, meta, from_package, edge, nodes, declared)
        end
      end
      entries.uniq.sort_by { |e| [e[:from], e[:to], e[:via]] }
    end

    # package identifier => Set of package identifiers it declares as
    # dependencies, read from that package unit's own `:package_dependency`
    # edges. A root package (`.`) declaring nothing is just another entry
    # with an empty Set, no special-cased root handling.
    #
    # @param nodes [Hash]
    # @return [Hash{String => Set<String>}]
    def package_declarations(nodes)
      nodes.each_with_object({}) do |(identifier, meta), declared|
        next unless meta[:type] == :package

        declared[identifier] = @graph.dependencies_of(identifier, via: :package_dependency).to_set
      end
    end

    # @return [Hash, nil] the report entry, or nil when the edge stays inside declared boundaries
    def undeclared_entry(from, from_meta, from_package, edge, nodes, declared)
      to = edge[:target]
      to_meta = nodes[to]
      to_package = to_meta && to_meta[:package]
      return nil if to_package.nil? || to_package == from_package

      declared_deps = declared[from_package] || Set.new
      return nil if declared_deps.include?(to_package)

      {
        from: from, from_type: from_meta[:type], to: to, to_type: to_meta[:type], via: edge[:via].to_s,
        from_package: from_package, to_package: to_package
      }
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
      @cycle_limit_reached = false
      return [] if nodes.empty?

      white = 0
      gray  = 1
      black = 2

      color = Hash.new(white)
      parent = {}
      found_cycles = []
      seen_cycle_signatures = Set.new

      catch(:cycle_limit) do
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
                collect_cycle(path, neighbor, found_cycles, seen_cycle_signatures)
              end
              # black nodes are fully explored, skip them
            end
          end
        end
      end

      # Deterministic without a final sort: the DFS starts from a sorted
      # node list, so cycles are discovered in the same order every run.
      found_cycles
    end

    # Record the cycle closed by a back-edge to +cycle_start+.
    #
    # Skips a cycle longer than the length cap and one already recorded under
    # another rotation. Throws +:cycle_limit+ once the count cap is full,
    # which ends the whole scan in {#detect_cycles}.
    #
    # @param path [Array<String>] Current DFS path
    # @param cycle_start [String] The node that closes the cycle
    # @param found_cycles [Array<Array<String>>] Accumulator
    # @param seen [Set<String>] Signatures already recorded
    # @return [void]
    def collect_cycle(path, cycle_start, found_cycles, seen)
      cycle = extract_cycle_from_path(path, cycle_start, max_length: @cycle_max_length)
      if cycle == :too_long
        @cycle_limit_reached = true
        return
      end
      return unless cycle

      signature = normalize_cycle_signature(cycle)
      return if seen.include?(signature)

      seen.add(signature)
      found_cycles << cycle
      return unless @cycle_limit && found_cycles.size >= @cycle_limit

      @cycle_limit_reached = true
      throw :cycle_limit
    end

    # Extracts a cycle from the current DFS path when a back-edge to
    # +cycle_start+ is found.
    #
    # The length check runs on indexes, before the slice: an over-long cycle
    # costs nothing beyond the +index+ lookup that found it.
    #
    # @param path [Array<String>] Current DFS path
    # @param cycle_start [String] The node that closes the cycle
    # @param max_length [Integer, nil] Longest cycle to build, in distinct nodes
    # @return [Array<String>, Symbol, nil] The cycle path ending with cycle_start
    #   repeated; +:too_long+ when it exceeds +max_length+; nil when cycle_start
    #   is not in the path
    def extract_cycle_from_path(path, cycle_start, max_length: nil)
      start_index = path.index(cycle_start)
      return nil unless start_index
      return :too_long if max_length && (path.size - start_index) > max_length

      path[start_index..] + [cycle_start]
    end

    # Normalize a cycle so that duplicate rotations are treated as the same cycle.
    # For example, [A, B, C, A] and [B, C, A, B] are the same cycle.
    #
    # Keyed by digest rather than by the joined path: the set holds one
    # 64-byte key per cycle instead of a string as long as the cycle, so
    # membership stays constant-cost however deep the DFS went.
    #
    # @param cycle [Array<String>] Cycle path with repeated last element
    # @return [String] Canonical hex digest of the rotated loop
    def normalize_cycle_signature(cycle)
      # Remove the trailing repeated element to get the raw loop
      loop_nodes = cycle[0..-2]
      return Digest::SHA256.hexdigest('') if loop_nodes.empty?

      # Rotate so the lexicographically smallest element is first
      min_index = loop_nodes.each_with_index.min_by { |node, _i| node }.last
      Digest::SHA256.hexdigest(loop_nodes.rotate(min_index).join('->'))
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
