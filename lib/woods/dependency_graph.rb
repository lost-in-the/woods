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
      @nodes = {}      # identifier => { type => { type:, file_path:, namespace: } }
      @edges = {}      # identifier => { type => [{ target:, via: }] }
      @reverse = {}    # identifier => Set of dependent identifiers
      @reverse_via = {} # [target, via] => Set of dependent identifiers
      @file_map = {}   # file_path => Set of identifiers (one file can define many units)
      @type_index = {} # type => Set of identifiers
      @to_h = nil
      @suffix_groups = nil
    end

    # Register a unit in the graph.
    #
    # Re-registering the same (identifier, type) — incremental extraction
    # registers into a graph loaded from disk — first removes that
    # registration's reverse edges, file-map entry, and type-index entry;
    # otherwise stale dependents accumulate across incremental runs and get
    # persisted back to dependency_graph.json.
    #
    # Re-registering the same identifier under a *different* type does not
    # displace the first unit (#225). A Scenic view `reports` and a factory
    # `reports` are two units, the index writes them to two files
    # (`database_view/reports.json`, `factory/reports.json`), and the graph
    # holds them as two nodes under one identifier.
    #
    # @param unit [ExtractedUnit] The unit to register
    def register(unit)
      @to_h = nil
      @suffix_groups = nil

      unregister(unit.identifier, type: unit.type) if @nodes[unit.identifier]&.key?(unit.type)

      (@nodes[unit.identifier] ||= {})[unit.type] = {
        type: unit.type,
        file_path: unit.file_path,
        namespace: unit.namespace
      }

      (@edges[unit.identifier] ||= {})[unit.type] =
        unit.dependencies.map { |d| { target: d[:target], via: d[:via] } }
      (@file_map[unit.file_path] ||= Set.new).add(unit.identifier) if unit.file_path

      # Type index for filtering (Set-based for O(1) insert)
      (@type_index[unit.type] ||= Set.new).add(unit.identifier)

      # Build reverse edges (Set-based for O(1) insert)
      unit.dependencies.each do |dep|
        (@reverse[dep[:target]] ||= Set.new).add(unit.identifier)
        (@reverse_via[[dep[:target], dep[:via]]] ||= Set.new).add(unit.identifier)
      end
    end

    # Remove a registration's side effects: its contribution to the reverse
    # indexes (derived from its recorded forward edges), its file-map entry,
    # and its type-index entry. Forward node/edge data is overwritten by the
    # caller (register), so it is not cleared here.
    #
    # Scoped to one type when `type:` is given, so re-registering a Scenic
    # view `reports` leaves a factory `reports` untouched. Without it, every
    # type registered under the identifier is stripped — which is what a
    # caller deleting the identifier outright wants.
    #
    # The reverse indexes are keyed on the *target* identifier and hold source
    # identifiers, not (identifier, type) pairs: a dependency names a target
    # by identifier alone, so there is no type to key on. A source's
    # contribution is therefore only withdrawn once its **last** remaining
    # type stops pointing at that target.
    #
    # @param identifier [String] Previously-registered unit identifier
    # @param type [Symbol, nil] Restrict to one registered type
    # @return [void]
    def unregister(identifier, type: nil)
      withdrawing = registered_types(identifier, type).to_set

      withdrawing.each do |t|
        withdraw_reverse_edges(identifier, t, withdrawing)

        old_node = @nodes[identifier]&.[](t)
        next unless old_node

        drop_from_file_map(identifier, old_node[:file_path], withdrawing)
        drop_from_type_index(identifier, old_node[:type])
      end
    end

    # Retract one registration's forward edges from the reverse indexes,
    # keeping any contribution the identifier's *other* types still make to
    # the same target.
    #
    # @param identifier [String]
    # @param type [Symbol, nil]
    # @param withdrawing [Set<Symbol>] every type being withdrawn in this call
    # @return [void]
    def withdraw_reverse_edges(identifier, type, withdrawing)
      surviving = surviving_edges(identifier, withdrawing)
      surviving_targets = surviving.to_set(&:first)

      Array(@edges[identifier]&.[](type)).each do |edge|
        if !surviving_targets.include?(edge[:target]) && (set = @reverse[edge[:target]])
          set.delete(identifier)
          @reverse.delete(edge[:target]) if set.empty?
        end

        via_key = [edge[:target], edge[:via]]
        next if surviving.include?(via_key)
        next unless (set = @reverse_via[via_key])

        set.delete(identifier)
        @reverse_via.delete(via_key) if set.empty?
      end
    end
    private :withdraw_reverse_edges

    # `[target, via]` pairs the identifier's *other* types still record, which
    # must keep their reverse entries when one type is withdrawn.
    #
    # @param identifier [String]
    # @param withdrawing [Set<Symbol>] the types being withdrawn
    # @return [Set<Array>] surviving `[target, via]` pairs
    def surviving_edges(identifier, withdrawing)
      (@edges[identifier] || {}).each_with_object(Set.new) do |(other_type, edges), set|
        next if withdrawing.include?(other_type)

        edges.each { |edge| set.add([edge[:target], edge[:via]]) }
      end
    end
    private :surviving_edges

    # Drop an identifier from a path's file-map entry, unless another of its
    # types still claims that path.
    #
    # @param identifier [String]
    # @param path [String, nil]
    # @param withdrawing [Set<Symbol>] types being withdrawn, which do not count
    #   as claimants — the node is still in `@nodes` at this point, since
    #   `register` overwrites it only after `unregister` returns
    # @return [void]
    def drop_from_file_map(identifier, path, withdrawing)
      return unless path

      return if (@nodes[identifier] || {}).any? do |type, node|
        !withdrawing.include?(type) && node[:file_path] == path
      end

      return unless (ids = @file_map[path])

      ids.delete(identifier)
      @file_map.delete(path) if ids.empty?
    end
    private :drop_from_file_map

    # Drop an identifier from a type bucket.
    #
    # @param identifier [String]
    # @param type [Symbol, nil]
    # @return [void]
    def drop_from_type_index(identifier, type)
      return unless (type_ids = @type_index[type])

      type_ids.delete(identifier)
      # Drop the key when the last unit of a type goes away — a full
      # extraction never emits an empty type bucket, and a stale empty one
      # would show up in to_h[:type_index] and stats[:types] as a phantom.
      @type_index.delete(type) if type_ids.empty?
    end
    private :drop_from_type_index

    # Types registered under an identifier, or the one requested.
    #
    # Reads from `@edges` as well as `@nodes`: a graph restored by {.from_h}
    # from a hash carrying edges for an identifier it has no node for still
    # has to be able to withdraw them.
    #
    # @param identifier [String]
    # @param type [Symbol, nil] restrict to this one when given
    # @return [Array<Symbol, nil>]
    def registered_types(identifier, type = nil)
      return [type] if type

      ((@nodes[identifier]&.keys || []) | (@edges[identifier]&.keys || []))
    end
    private :registered_types

    # Fully remove a unit from the graph — node, forward edges, reverse-edge
    # contributions, file-map entry, and type-index entry.
    #
    # Distinct from {#unregister}, which strips only the *side effects* of a
    # registration so the same identifier can be re-registered on top; this
    # is the deletion path used when a source file disappears. Reverse
    # entries keyed *on* the removed identifier are intentionally left alone:
    # they are derived from other units' forward edges, which are unchanged,
    # and a full extraction records them the same way (a dependency target
    # need not be a registered node).
    #
    # @param identifier [String] Unit identifier to remove
    # @param type [Symbol, nil] Remove only this type's node; without it every
    #   node registered under the identifier goes. A caller pruning a deleted
    #   source file must pass the type, or it deletes the same-named unit of
    #   another type along with it (#225).
    # @return [Hash, nil] the removed node, or nil if it was not registered
    def remove(identifier, type: nil)
      nodes = @nodes[identifier]
      return nil unless nodes&.any?
      return nil if type && !nodes.key?(type)

      @to_h = nil
      @suffix_groups = nil
      unregister(identifier, type: type)

      return remove_all(identifier, nodes) unless type

      remaining_edges = @edges[identifier]
      remaining_edges&.delete(type)
      @edges.delete(identifier) if remaining_edges && remaining_edges.empty?
      removed = nodes.delete(type)
      @nodes.delete(identifier) if nodes.empty?
      removed
    end

    # @param identifier [String]
    # @param nodes [Hash{Symbol => Hash}] every node under the identifier
    # @return [Hash, nil] the primary node, matching the pre-#225 return value
    def remove_all(identifier, nodes)
      primary = primary_of(nodes)
      @edges.delete(identifier)
      @nodes.delete(identifier)
      primary
    end
    private :remove_all

    # Identifiers defined by a given file path.
    #
    # A single file can define several units (a `.rake` file with multiple
    # tasks, an i18n YAML file, a lib file holding several classes), so this
    # returns a list rather than a single identifier.
    #
    # @param file_path [String] Absolute file path as registered
    # @return [Array<String>] Identifiers defined by that file (possibly empty)
    def identifiers_for_path(file_path)
      (@file_map[file_path] || []).to_a
    end

    # Every file path currently registered in the graph.
    #
    # @return [Array<String>]
    def registered_paths
      @file_map.keys
    end

    # Find all units affected by changes to given files
    # Uses BFS to find transitive dependents
    #
    # @param changed_files [Array<String>] List of changed file paths
    # @param max_depth [Integer] Maximum traversal depth (nil for unlimited)
    # @return [Array<String>] List of affected unit identifiers
    def affected_by(changed_files, max_depth: nil)
      directly_changed = changed_files.flat_map { |f| (@file_map[f] || []).to_a }.uniq

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

    # Fetch a node's metadata without materializing the whole graph.
    #
    # {#to_h} is memoized but rebuilds on every register/remove, so reaching
    # for `to_h[:nodes][id]` inside a loop is quadratic. Use this instead.
    #
    # Without `type:` this answers with the **primary** node — the one whose
    # type sorts first. It is deterministic on purpose: picking by
    # registration order would let a full and an incremental extraction of one
    # tree disagree about which of two colliding units is "the" node, and the
    # graph's published artifacts have to be a pure function of its content.
    # A caller that must not guess should use {#nodes_for} or {#node_types}.
    #
    # @param identifier [String] Unit identifier
    # @param type [Symbol, nil] Exact type to look up
    # @return [Hash, nil] `{ type:, file_path:, namespace: }` or nil
    def node(identifier, type: nil)
      nodes = @nodes[identifier]
      return nil unless nodes

      type ? nodes[type] : primary_of(nodes)
    end

    # Every node registered under an identifier, sorted by type.
    #
    # One entry for all but the handful of identifiers a codebase reuses
    # across unit types (a Scenic view and a factory both called `reports`).
    #
    # @param identifier [String] Unit identifier
    # @return [Array<Hash>] `{ type:, file_path:, namespace: }` entries
    def nodes_for(identifier)
      sorted_nodes(@nodes[identifier] || {}).map(&:last)
    end

    # Types registered under an identifier, sorted.
    #
    # @param identifier [String] Unit identifier
    # @return [Array<Symbol>]
    def node_types(identifier)
      sorted_nodes(@nodes[identifier] || {}).map(&:first)
    end

    # The (identifier, type) pairs a file defines.
    #
    # {#identifiers_for_path} answers with identifiers alone, which is
    # ambiguous for a colliding identifier — a caller deleting the units of a
    # vanished file needs to know *which* node that path registered, or it
    # deletes the same-named unit of another type too.
    #
    # An identifier whose nodes name no matching `file_path` still yields every
    # one of its types. The file map is the authority on which identifiers a
    # path defines — a persisted graph can carry a file-map key that does not
    # match its node's recorded path, and dropping the identifier there would
    # make this see *less* than {#identifiers_for_path} does.
    #
    # @param file_path [String] Absolute file path as registered
    # @return [Array<Array(String, Symbol)>] `[identifier, type]` pairs
    def units_for_path(file_path)
      (@file_map[file_path] || []).flat_map do |identifier|
        nodes = sorted_nodes(@nodes[identifier] || {})
        at_path = nodes.select { |_, node| node[:file_path] == file_path }
        (at_path.empty? ? nodes : at_path).map { |type, _| [identifier, type] }
      end
    end

    # @param nodes [Hash{Symbol => Hash}]
    # @return [Array<Array(Symbol, Hash)>] sorted by type name; a nil type
    #   (an edges-only entry restored from a hash with no matching node) sorts
    #   first, since it cannot be compared against a Symbol
    def sorted_nodes(nodes)
      nodes.sort_by { |type, _| [type ? 1 : 0, type.to_s] }
    end
    private :sorted_nodes

    # @param nodes [Hash{Symbol => Hash}]
    # @return [Hash, nil]
    def primary_of(nodes)
      sorted_nodes(nodes).first&.last
    end
    private :primary_of

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
    # Find a namespaced node by its unqualified short name.
    #
    # Backed by a memoized index rather than a scan. This is called once per
    # operation while assembling an execution flow, so on a host with tens of
    # thousands of nodes a single flow paid a linear pass over all of them for
    # every call target it encountered.
    #
    # The index also makes the answer deterministic where several namespaced
    # identifiers share a short name: the first in sorted order wins, whereas
    # the scan returned whichever was registered first — so the same flow could
    # resolve differently after an incremental run than after a full one.
    #
    # @param suffix [String] unqualified name, e.g. "Payment"
    # @return [String, nil] the full identifier, e.g. "Billing::Payment"
    def find_node_by_suffix(suffix)
      suffix_groups[suffix]&.first
    end

    # Every namespaced identifier sharing +suffix+ as its unqualified short
    # name — the full multiplicity {#find_node_by_suffix} collapses to its
    # first (sorted) match.
    #
    # {#find_node_by_suffix}'s single-result contract stays exactly as it
    # was for existing callers; this is additive, for a caller (the flow
    # assembler) that needs to know whether a suffix resolution was
    # ambiguous — several namespaces sharing one short name — instead of
    # trusting whichever candidate the single-result method happened to
    # pick.
    #
    # @param suffix [String] unqualified name, e.g. "Update"
    # @return [Array<String>] every matching full identifier, sorted; empty
    #   when nothing matches
    def find_all_by_suffix(suffix)
      suffix_groups.fetch(suffix, []).dup
    end

    # Get direct dependencies of a unit
    #
    # Without `type:` this is the **union** across every type registered under
    # the identifier. The caller is blast-radius computation, where a superset
    # is safe and a subset silently under-extracts; for the identifiers that
    # are not shared across types — all but a handful in any real index — the
    # union is the same single list it always was.
    #
    # @param identifier [String] Unit identifier
    # @param via [Symbol, Array<Symbol>, nil] Filter by relationship type(s)
    # @param type [Symbol, nil] Restrict to one registered unit type
    # @return [Array<String>] List of dependency identifiers
    def dependencies_of(identifier, via: nil, type: nil)
      edges = edges_for(identifier, type)
      if via
        via_set = Array(via)
        edges = edges.select { |e| via_set.include?(e[:via]) }
      end
      edges.map { |e| e[:target] }
    end

    # @param identifier [String]
    # @param type [Symbol, nil] one registered type, or every one when nil
    # @return [Array<Hash>] `{ target:, via: }` edges, in type-sorted order
    def edges_for(identifier, type = nil)
      by_type = @edges[identifier] || {}
      return Array(by_type[type]) if type

      by_type.sort_by { |t, _| [t ? 1 : 0, t.to_s] }.flat_map { |_, edges| edges }
    end
    private :edges_for

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

    # Dependents of a unit in the shape {Extractor#resolve_dependents} writes
    # into unit JSON: `{ type:, identifier: }` per *edge*, not per source.
    #
    # Multiplicity is preserved deliberately — a source that references the
    # same target twice (say once as `:belongs_to` and once as
    # `:code_reference`) contributes two entries in a full extraction, so
    # reconstructing this list incrementally has to do the same or the two
    # paths produce different unit JSON. Order is registration order and is
    # not guaranteed to match a full extraction's; callers comparing the two
    # should compare as multisets.
    #
    # @param identifier [String] Unit identifier
    # @return [Array<Hash>] `{ type: Symbol, identifier: String }` entries
    def dependents_detail(identifier)
      (@reverse[identifier] || []).flat_map do |source|
        sorted_nodes(@nodes[source] || {}).flat_map do |type, node|
          edge_count = Array(@edges[source]&.[](type)).count { |e| e[:target] == identifier }
          Array.new(edge_count) { { type: node[:type], identifier: source } }
        end
      end
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
    # Mass is conserved (#205): a source's out-degree counts only edges whose
    # target is a registered node, **with multiplicity**. Two edges to one
    # target (`:belongs_to` + `:code_reference` is documented normal — see
    # {#dependents_detail}) deliver twice the share, and edges to unregistered
    # targets (gem or framework constants) neither dilute the distribution nor
    # swallow the source's mass. A node whose every edge is unresolvable is
    # dangling, exactly like a node with no edges at all — its rank
    # redistributes uniformly instead of vanishing.
    #
    # @param damping [Float] Damping factor (default: 0.85)
    # @param iterations [Integer] Number of iterations (default: 20)
    # @return [Hash<String, Float>] Identifier => PageRank score
    def pagerank(damping: 0.85, iterations: 20)
      n = @nodes.size
      return {} if n.zero?

      node_ids = @nodes.keys
      weights = resolvable_edge_weights
      base_score = 1.0 / n
      scores = node_ids.to_h { |id| [id, base_score] }

      iterations.times do
        scores = pagerank_step(node_ids, scores, weights, damping)
      end

      scores
    end

    private

    # short name => every full identifier sharing it, for
    # {#find_node_by_suffix} and {#find_all_by_suffix}.
    #
    # Only namespaced identifiers contribute — an unnamespaced `User` is found
    # by {#node_exists?} before the suffix tier is reached. Each bucket is
    # sorted so a short name claimed by several namespaces resolves to the
    # same first candidate every time. Invalidated wherever `@to_h` is, since
    # both derive from `@nodes`.
    #
    # @return [Hash{String => Array<String>}]
    def suffix_groups
      return @suffix_groups if @suffix_groups

      groups = @nodes.keys.each_with_object({}) do |identifier, index|
        short = identifier.split('::').last
        next if short == identifier

        (index[short] ||= []) << identifier
      end
      groups.each_value(&:sort!)
      @suffix_groups = groups
    end

    # One PageRank power iteration over precomputed resolvable-edge weights.
    #
    # Iteration order (node insertion order, reverse-Set insertion order) is
    # the same stable order the pre-#205 implementation used, so two runs
    # over the same graph produce identical floats.
    #
    # @param node_ids [Array<String>] All registered identifiers
    # @param scores [Hash{String => Float}] Scores from the previous iteration
    # @param weights [Hash{String => Array(Hash, Integer)}] See {#resolvable_edge_weights}
    # @param damping [Float] Damping factor
    # @return [Hash{String => Float}] Next iteration's scores
    def pagerank_step(node_ids, scores, weights, damping)
      n = node_ids.size
      # Collect rank from dangling nodes (no *resolvable* outgoing edges) and redistribute
      dangling_sum = node_ids.sum { |id| weights.key?(id) ? 0.0 : scores[id] }

      node_ids.to_h do |id|
        # Sum contributions from nodes that depend on this one
        rank_sum = (@reverse[id] || []).sum do |src|
          counts, out_degree = weights[src]
          multiplicity = counts ? counts[id] : 0
          multiplicity.positive? ? scores[src] * multiplicity / out_degree : 0.0
        end

        [id, ((1.0 - damping) / n) + (damping * (rank_sum + (dangling_sum / n)))]
      end
    end

    # Per-source PageRank link weights over **resolvable** edges only — edges
    # whose target is a registered node. Built once per {#pagerank} run in
    # O(edges), so the per-iteration loops stay O(nodes + reverse edges).
    #
    # Each entry is `[target => multiplicity, resolvable out-degree]`; the
    # out-degree is the multiplicity sum, so a duplicated edge weighs double
    # rather than leaking. Sources with zero resolvable edges are absent,
    # which is what marks them dangling in {#pagerank_step}.
    #
    # @return [Hash{String => Array(Hash{String => Integer}, Integer)}]
    def resolvable_edge_weights
      @edges.each_with_object({}) do |(src, by_type), weights|
        counts = nil
        by_type.each_value do |edges|
          edges.each do |edge|
            next unless @nodes.key?(edge[:target])

            (counts ||= Hash.new(0))[edge[:target]] += 1
          end
        end

        weights[src] = [counts, counts.each_value.sum] if counts
      end
    end

    public

    # Serialize graph for persistence. Memoized — cache is invalidated on register.
    # Returns a dup so callers can't pollute the cached hash.
    #
    # ## Wire format and the `variants` key (#225)
    #
    # `nodes` and `edges` stay keyed on the bare identifier, holding the
    # **primary** node — the type that sorts first. Identifiers registered
    # under more than one type put their remaining nodes in `variants`, a flat
    # array that is **omitted entirely when empty**. So the serialized form of
    # a graph with no collisions is byte-for-byte what it has always been, and
    # a `dependency_graph.json` written before this change loads through
    # {.from_h} unmodified: it simply carries no `variants`.
    #
    # `reverse`, `file_map` and `type_index` need no new shape. They are
    # already identifier-valued sets, so a Scenic view `reports` and a factory
    # `reports` each contribute to their own type bucket and their own path.
    #
    # @return [Hash] Complete graph data
    def to_h
      root = self.class.graph_root
      @to_h ||= begin
        variants = self.class.relativize_variants(variant_records, root)
        base = {
          nodes: self.class.relativize_nodes(primary_nodes, root),
          edges: primary_edges,
          reverse: @reverse.transform_values(&:to_a),
          file_map: self.class.relativize_file_map(@file_map, root),
          type_index: @type_index.transform_values(&:to_a),
          stats: {
            node_count: @nodes.each_value.sum(&:size),
            edge_count: @edges.each_value.sum { |by_type| by_type.each_value.sum(&:size) },
            types: @type_index.transform_values(&:size)
          }
        }
        variants.empty? ? base : base.merge(variants: variants)
      end
      @to_h.dup
    end

    # @return [Hash{String => Hash}] identifier => primary node
    def primary_nodes
      @nodes.transform_values { |nodes| primary_of(nodes) }
    end
    private :primary_nodes

    # @return [Hash{String => Array<Hash>}] identifier => primary node's edges
    def primary_edges
      @edges.each_with_object({}) do |(identifier, by_type), edges|
        primary_type = primary_type_for(identifier, by_type)
        edges[identifier] = by_type.fetch(primary_type, [])
      end
    end
    private :primary_edges

    # Every non-primary node, flattened for serialization. Each record carries
    # its own edges, so a variant round-trips whole.
    #
    # @return [Array<Hash>] sorted by identifier then type, so two extractions
    #   of one tree serialize identically
    def variant_records
      records = @nodes.flat_map do |identifier, nodes|
        sorted_nodes(nodes).drop(1).map do |type, node|
          {
            identifier: identifier,
            type: type,
            file_path: node[:file_path],
            namespace: node[:namespace],
            edges: @edges[identifier]&.[](type) || []
          }
        end
      end
      records.sort_by { |record| [record[:identifier], record[:type].to_s] }
    end
    private :variant_records

    # The type whose node is primary for an identifier. Falls back to the
    # edges' own first type when there is no node — {.from_h} accepts a hash
    # carrying edges for an identifier it has no node for.
    #
    # @param identifier [String]
    # @param by_type [Hash{Symbol => Array<Hash>}] that identifier's edges
    # @return [Symbol, nil]
    def primary_type_for(identifier, by_type)
      nodes = @nodes[identifier]
      return sorted_nodes(nodes).first&.first if nodes&.any?

      by_type.keys.first
    end
    private :primary_type_for

    # ── Path portability (#166) ────────────────────────────────────────────
    #
    # The graph holds **absolute** paths in memory, because every consumer of
    # them resolves against the filesystem in the extracting process:
    # `re_extract_unit` and `incremental_git_data` both gate on `File.exist?`,
    # and `affected_by` / `identifiers_for_path` are handed absolute paths by
    # `ChangeSet`. Persisting them absolute made the artifact non-portable —
    # extraction in a container writes `/app/...` while a host reading the
    # volume mount sees `/Users/.../woods/...`, so a host-run `woods:incremental`
    # computed an empty blast radius and silently re-extracted nothing.
    #
    # So paths are relativized on the way out and absolutized on the way back.
    # Nothing on the read side is affected: no MCP tool, exporter or formatter
    # reads a graph node's `file_path` — they all read the per-unit JSON, which
    # has always been relative.
    #
    # Absolutizing is idempotent for a path that is already absolute, which is
    # what lets a graph persisted before this load without a re-index — the same
    # approach {normalize_edges} and {normalize_file_map} take for their own
    # legacy formats.

    # @return [String, nil] the extraction root, or nil outside a Rails process
    #   (a host-side reader), in which case paths pass through untouched
    def self.graph_root
      return nil unless defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      Rails.root.to_s
    end

    # @return [String, nil] path relative to root, or unchanged when it is nil,
    #   root is unknown, or it lives outside the tree (a gem path)
    def self.relativize(path, root)
      return path if path.nil? || root.nil?

      prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      path.start_with?(prefix) ? path.delete_prefix(prefix) : path
    end

    # @return [String, nil] absolute path, or unchanged when it is nil, root is
    #   unknown, or it is already absolute (a pre-#166 graph, or a gem path)
    def self.absolutize(path, root)
      return path if path.nil? || root.nil?
      return path if path.start_with?(File::SEPARATOR)

      File.join(root, path)
    end

    def self.relativize_nodes(nodes, root)
      return nodes if root.nil?

      nodes.transform_values do |node|
        node[:file_path] ? node.merge(file_path: relativize(node[:file_path], root)) : node
      end
    end

    def self.absolutize_nodes(nodes, root)
      return nodes if root.nil?

      nodes.transform_values do |node|
        node[:file_path] ? node.merge(file_path: absolutize(node[:file_path], root)) : node
      end
    end

    # Variant records carry a `file_path` like any other node, so they move
    # with the same rules — relative on the way out, absolute on the way back.
    def self.relativize_variants(variants, root)
      return variants if root.nil?

      variants.map do |record|
        record[:file_path] ? record.merge(file_path: relativize(record[:file_path], root)) : record
      end
    end

    # Serialization form: **arrays**, matching what `to_h` has always emitted.
    def self.relativize_file_map(file_map, root)
      relocate_file_map(file_map) { |path| relativize(path, root) }
        .transform_values(&:to_a)
    end

    # In-memory form: **Sets**, which is the `@file_map` contract every path
    # lookup depends on. Returning arrays here would break `#unregister`, which
    # calls `Set#delete` on the value.
    def self.absolutize_file_map(file_map, root)
      relocate_file_map(file_map) { |path| absolutize(path, root) }
    end

    # Rekey a file map, merging rather than overwriting: two keys can collapse
    # onto one after transformation — a path inside the root and its
    # already-relative twin from a pre-#166 graph — and the identifiers of both
    # belong to the survivor. Values come back as Sets; callers that need the
    # serialized shape convert.
    def self.relocate_file_map(file_map)
      file_map.each_with_object({}) do |(path, ids), moved|
        key = yield(path)
        (moved[key] ||= Set.new).merge(ids.is_a?(Set) ? ids : Array(ids))
      end
    end

    # Load graph from persisted data
    #
    # After JSON round-trip all keys become strings. This method normalizes
    # them back to the expected types: node values use symbol keys (:type,
    # :file_path, :namespace), and type_index uses symbol keys for types.
    #
    # The root is resolved ambiently rather than accepted as a keyword. Adding a
    # `root:` kwarg here silently breaks every caller that passes a bare hash
    # literal — `from_h('nodes' => ..., 'file_map' => ...)` binds as *keywords*
    # once the method accepts any, so `data` arrives empty and the call raises
    # ArgumentError. The specs in this file call it exactly that way.
    #
    # @param data [Hash] Previously serialized graph data
    # @return [DependencyGraph] Restored graph
    def self.from_h(data)
      graph = new

      root = graph_root

      raw_nodes = data[:nodes] || data['nodes'] || {}
      flat_nodes = absolutize_nodes(raw_nodes.transform_values { |v| symbolize_node(v) }, root)
      nodes = flat_nodes.transform_values { |node| { node[:type] => node } }

      raw_edges = data[:edges] || data['edges'] || {}
      edges = raw_edges.each_with_object({}) do |(identifier, list), by_identifier|
        # A hash carrying edges for an identifier it has no node for keys them
        # under nil — the same type `symbolize_node` would have produced.
        type = nodes[identifier]&.keys&.first
        by_identifier[identifier] = { type => normalize_edges(list) }
      end

      merge_variants(data[:variants] || data['variants'], nodes, edges, root)

      graph.instance_variable_set(:@nodes, nodes)
      graph.instance_variable_set(:@edges, edges)

      raw_reverse = data[:reverse] || data['reverse'] || {}
      graph.instance_variable_set(:@reverse, raw_reverse.transform_values { |v| v.is_a?(Set) ? v : Set.new(v) })

      raw_file_map = data[:file_map] || data['file_map'] || {}
      graph.instance_variable_set(:@file_map, absolutize_file_map(normalize_file_map(raw_file_map), root))

      raw_type_index = data[:type_index] || data['type_index'] || {}
      graph.instance_variable_set(:@type_index, raw_type_index.transform_keys(&:to_sym).transform_values do |v|
        v.is_a?(Set) ? v : Set.new(v)
      end)

      # Rebuild reverse_via index from edges
      reverse_via = {}
      graph.instance_variable_get(:@edges).each do |source_id, by_type|
        by_type.each_value do |edge_list|
          edge_list.each do |edge|
            (reverse_via[[edge[:target], edge[:via]]] ||= Set.new).add(source_id)
          end
        end
      end
      graph.instance_variable_set(:@reverse_via, reverse_via)

      graph
    end

    # Fold the `variants` section back into the nested node/edge hashes.
    #
    # Absent (every graph written before #225, and every graph with no
    # identifier shared across types) this is a no-op, which is what makes the
    # format backward compatible without a migration.
    #
    # @param raw [Array<Hash>, nil] the persisted `variants` array
    # @param nodes [Hash] identifier => { type => node }, mutated in place
    # @param edges [Hash] identifier => { type => edges }, mutated in place
    # @param root [String, nil] extraction root for path absolutizing
    # @return [void]
    def self.merge_variants(raw, nodes, edges, root)
      return unless raw.is_a?(Array)

      raw.each do |record|
        next unless record.is_a?(Hash)

        identifier = record[:identifier] || record['identifier']
        type = (record[:type] || record['type'])&.to_sym
        next if identifier.nil? || type.nil?

        (nodes[identifier] ||= {})[type] = {
          type: type,
          file_path: absolutize(record[:file_path] || record['file_path'], root),
          namespace: record[:namespace] || record['namespace']
        }
        (edges[identifier] ||= {})[type] = normalize_edges(record[:edges] || record['edges'])
      end
    end
    private_class_method :merge_variants

    # Normalize a persisted file map to `path => Set<identifier>`.
    #
    # Graphs written before the multi-valued migration stored a single
    # identifier per path (`{"app/models/user.rb" => "User"}`), which silently
    # lost every unit but the last for files defining several units (a `.rake`
    # file with multiple tasks, an i18n YAML, a lib file with several classes).
    # Old graphs load without conversion — the bare string is wrapped — so the
    # first incremental run after upgrading re-widens the map as it
    # re-registers units.
    #
    # @param raw [Hash] Persisted file_map (values are String, Array, or Set)
    # @return [Hash{String => Set<String>}]
    def self.normalize_file_map(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(path, ids), map|
        map[path] = case ids
                    when Set then ids
                    when Array then Set.new(ids)
                    when nil then Set.new
                    else Set.new([ids])
                    end
      end
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
