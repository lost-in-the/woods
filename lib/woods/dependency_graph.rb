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
      @file_map = {}   # file_path => Set of identifiers (one file can define many units)
      @type_index = {} # type => Set of identifiers
      @to_h = nil
      @suffix_index = nil
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
      @suffix_index = nil

      unregister(unit.identifier) if @nodes.key?(unit.identifier)

      @nodes[unit.identifier] = {
        type: unit.type,
        file_path: unit.file_path,
        namespace: unit.namespace
      }

      @edges[unit.identifier] = unit.dependencies.map { |d| { target: d[:target], via: d[:via] } }
      (@file_map[unit.file_path] ||= Set.new).add(unit.identifier) if unit.file_path

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
      if old_path && (ids = @file_map[old_path])
        ids.delete(identifier)
        @file_map.delete(old_path) if ids.empty?
      end

      return unless (type_ids = @type_index[old_node[:type]])

      type_ids.delete(identifier)
      # Drop the key when the last unit of a type goes away — a full
      # extraction never emits an empty type bucket, and a stale empty one
      # would show up in to_h[:type_index] and stats[:types] as a phantom.
      @type_index.delete(old_node[:type]) if type_ids.empty?
    end

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
    # @return [Hash, nil] the removed node, or nil if it was not registered
    def remove(identifier)
      return nil unless @nodes.key?(identifier)

      @to_h = nil
      @suffix_index = nil
      unregister(identifier)
      @edges.delete(identifier)
      @nodes.delete(identifier)
    end

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
    # @param identifier [String] Unit identifier
    # @return [Hash, nil] `{ type:, file_path:, namespace: }` or nil
    def node(identifier)
      @nodes[identifier]
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
      suffix_index[suffix]
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
        node = @nodes[source]
        next [] unless node

        edge_count = (@edges[source] || []).count { |e| e[:target] == identifier }
        Array.new(edge_count) { { type: node[:type], identifier: source } }
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

    # short name => full identifier, for {#find_node_by_suffix}.
    #
    # Only namespaced identifiers contribute — an unnamespaced `User` is found
    # by {#node_exists?} before the suffix tier is reached. Sorted so a short
    # name claimed by several namespaces resolves to the same one every time.
    # Invalidated wherever `@to_h` is, since both derive from `@nodes`.
    #
    # @return [Hash{String => String}]
    def suffix_index
      @suffix_index ||= @nodes.keys.sort.each_with_object({}) do |identifier, index|
        short = identifier.split('::').last
        next if short == identifier

        index[short] ||= identifier
      end
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
      @edges.each_with_object({}) do |(src, edges), weights|
        counts = nil
        edges.each do |edge|
          next unless @nodes.key?(edge[:target])

          (counts ||= Hash.new(0))[edge[:target]] += 1
        end

        weights[src] = [counts, counts.each_value.sum] if counts
      end
    end

    public

    # Serialize graph for persistence. Memoized — cache is invalidated on register.
    # Returns a dup so callers can't pollute the cached hash.
    #
    # @return [Hash] Complete graph data
    def to_h
      root = self.class.graph_root
      @to_h ||= {
        nodes: self.class.relativize_nodes(@nodes, root),
        edges: @edges,
        reverse: @reverse.transform_values(&:to_a),
        file_map: self.class.relativize_file_map(@file_map, root),
        type_index: @type_index.transform_values(&:to_a),
        stats: {
          node_count: @nodes.size,
          edge_count: @edges.values.sum(&:size),
          types: @type_index.transform_values(&:size)
        }
      }
      @to_h.dup
    end

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
      graph.instance_variable_set(
        :@nodes, absolutize_nodes(raw_nodes.transform_values { |v| symbolize_node(v) }, root)
      )

      raw_edges = data[:edges] || data['edges'] || {}
      graph.instance_variable_set(:@edges, raw_edges.transform_values { |edges| normalize_edges(edges) })

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
      graph.instance_variable_get(:@edges).each do |source_id, edges|
        edges.each do |edge|
          (reverse_via[[edge[:target], edge[:via]]] ||= Set.new).add(source_id)
        end
      end
      graph.instance_variable_set(:@reverse_via, reverse_via)

      graph
    end

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
