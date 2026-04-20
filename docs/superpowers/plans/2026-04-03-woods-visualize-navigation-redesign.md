# Woods Visualize Navigation Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the flat graph views with a Liam ERD-inspired three-zone layout: left sidebar for browsing/filtering, center canvas with enriched node rendering (model nodes show columns), right detail panel, and highlight/dim behavior for connected nodes.

**Architecture:** Incremental enhancement of the existing Svelte 5 + @xyflow/svelte + dagre stack. Ruby-side: enrich `NodeBuilder` output with columns/attributes/dependency counts by loading unit metadata from extraction output. Frontend: replace `WoodsNode.svelte` with `ModelNode.svelte` and `CompactNode.svelte`, add `Sidebar.svelte` and `TypeGroup.svelte`, refactor `App.svelte` state management, remove Flows tab. No new runtime dependencies.

**Tech Stack:** Ruby (RSpec), Svelte 5 (runes: `$state`, `$state.raw`, `$derived`, `$props`), @xyflow/svelte 1.x, @dagrejs/dagre 1.x, Vite 6.x

**Spec:** `docs/superpowers/specs/2026-04-03-woods-visualize-navigation-redesign.md`

---

## File Structure

### Ruby (Backend Enrichment)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `lib/woods/svelte_flow/node_builder.rb` | Add `columns`, `attributes`, `dependencyCount`, `dependentCount` to node data. Accept `unit_metadata` and `edges`/`reverse` hashes. |
| Modify | `lib/woods/svelte_flow/transformer.rb` | Load unit metadata from disk, pass to NodeBuilder. Clean up symbol-or-string fallbacks. Pass edges/reverse for dependency counts. |
| Modify | `lib/woods/svelte_flow/exporter.rb` | Load unit metadata index and pass to Transformer. |
| Modify | `spec/svelte_flow/node_builder_spec.rb` | Test columns, attributes, dependency counts |
| Modify | `spec/svelte_flow/transformer_spec.rb` | Test enriched node output, symbol cleanup |

### Frontend (Svelte Components)

| Action | File | Responsibility |
|--------|------|----------------|
| Create | `frontend/src/components/ModelNode.svelte` | Model node with header + column rows |
| Create | `frontend/src/components/CompactNode.svelte` | Non-model node with header + attribute rows |
| Create | `frontend/src/components/Sidebar.svelte` | Left panel: filter, type groups, visibility toggles, bulk actions |
| Create | `frontend/src/components/TypeGroup.svelte` | Collapsible section within sidebar |
| Modify | `frontend/src/App.svelte` | Three-zone layout, state management, highlight logic, remove Flows tab |
| Modify | `frontend/src/components/GraphView.svelte` | Accept visibility/highlight props, use ModelNode + CompactNode |
| Modify | `frontend/src/components/ClusterView.svelte` | Same sidebar integration as GraphView |
| Modify | `frontend/src/components/NodeDetail.svelte` | Add dependency/dependent counts, column detail for models |
| Modify | `frontend/src/lib/layout.js` | Dynamic node heights based on content |
| Modify | `frontend/src/lib/theme.js` | Add missing type colors per spec |
| Modify | `frontend/src/app.css` | Sidebar styles, node highlight/dim styles, grid layout update |
| Delete | `frontend/src/components/FlowView.svelte` | Flows tab deferred |
| Delete | `frontend/src/components/WoodsNode.svelte` | Replaced by ModelNode + CompactNode |

---

## Task 1: Enrich NodeBuilder with columns, attributes, and dependency counts

**Context:** The `NodeBuilder` currently outputs nodes with only `label`, `unitType`, `filePath`, `namespace`, `pagerank`, `isHub`, `isBridge`, `isOrphan`. The spec requires adding `columns` (for models), `attributes` (for non-models), `dependencyCount`, and `dependentCount`.

**Files:**
- Modify: `spec/svelte_flow/node_builder_spec.rb`
- Modify: `lib/woods/svelte_flow/node_builder.rb`

- [ ] **Step 1: Write failing specs for columns on model nodes**

Add to `spec/svelte_flow/node_builder_spec.rb` inside the `describe '#build'` block:

```ruby
context 'with unit metadata' do
  let(:unit_metadata) do
    {
      'User' => {
        'type' => 'model',
        'metadata' => {
          'primary_key' => 'id',
          'columns' => [
            { 'name' => 'id', 'type' => 'bigint', 'null' => false },
            { 'name' => 'account_id', 'type' => 'bigint', 'null' => false },
            { 'name' => 'name', 'type' => 'character varying(255)', 'null' => false },
            { 'name' => 'email', 'type' => 'character varying(255)', 'null' => true }
          ],
          'associations' => [
            { 'name' => 'account', 'macro' => 'belongs_to', 'foreign_key' => 'account_id' }
          ]
        }
      },
      'UsersController' => {
        'type' => 'controller',
        'metadata' => {
          'actions' => %w[index show create update destroy]
        }
      },
      'UserService' => {
        'type' => 'service',
        'metadata' => {}
      }
    }
  end

  let(:forward_edges) do
    { 'User' => %w[Post Comment], 'UsersController' => ['User'], 'UserService' => ['User'] }
  end

  let(:reverse_edges) do
    { 'User' => Set.new(%w[UsersController UserService]), 'Post' => Set.new(['User']), 'Comment' => Set.new(['User']) }
  end

  subject do
    described_class.new(
      nodes: nodes,
      positions: positions,
      pagerank: pagerank,
      analysis: analysis,
      unit_metadata: unit_metadata,
      forward_edges: forward_edges,
      reverse_edges: reverse_edges
    )
  end

  it 'includes columns array on model nodes' do
    user_node = subject.build.find { |n| n['id'] == 'User' }
    columns = user_node['data']['columns']

    expect(columns).to be_an(Array)
    expect(columns.size).to eq(4)
    expect(columns.first).to include('name' => 'id', 'type' => 'bigint', 'primary' => true, 'nullable' => false)
  end

  it 'marks foreign key columns' do
    user_node = subject.build.find { |n| n['id'] == 'User' }
    fk_col = user_node['data']['columns'].find { |c| c['name'] == 'account_id' }
    expect(fk_col['foreign']).to be true
  end

  it 'marks nullable columns' do
    user_node = subject.build.find { |n| n['id'] == 'User' }
    email_col = user_node['data']['columns'].find { |c| c['name'] == 'email' }
    expect(email_col['nullable']).to be true
  end

  it 'includes attributes array on controller nodes' do
    controller_node = subject.build.find { |n| n['id'] == 'UsersController' }
    expect(controller_node['data']['attributes']).to eq(%w[index show create update destroy])
  end

  it 'includes file path as attributes fallback for service nodes' do
    service_node = subject.build.find { |n| n['id'] == 'UserService' }
    expect(service_node['data']['attributes']).to eq(['app/services/user_service.rb'])
  end

  it 'does not include columns on non-model nodes' do
    controller_node = subject.build.find { |n| n['id'] == 'UsersController' }
    expect(controller_node['data']).not_to have_key('columns')
  end

  it 'includes dependencyCount from forward edges' do
    user_node = subject.build.find { |n| n['id'] == 'User' }
    expect(user_node['data']['dependencyCount']).to eq(2)
  end

  it 'includes dependentCount from reverse edges' do
    user_node = subject.build.find { |n| n['id'] == 'User' }
    expect(user_node['data']['dependentCount']).to eq(2)
  end

  it 'defaults counts to 0 when no edges exist' do
    service_node = subject.build.find { |n| n['id'] == 'UserService' }
    expect(service_node['data']['dependentCount']).to eq(0)
  end
end
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/svelte_flow/node_builder_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: FAIL — `ArgumentError: unknown keyword: :unit_metadata`

- [ ] **Step 3: Implement NodeBuilder enrichment**

Replace the full `lib/woods/svelte_flow/node_builder.rb`:

```ruby
# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Converts dependency graph nodes into Svelte Flow node objects.
    #
    # Maps unit types to custom Svelte Flow node types and enriches node data
    # with PageRank scores, structural roles (hub, bridge, orphan), columns
    # (for model nodes), attributes (for non-model nodes), and dependency counts.
    #
    # @example
    #   builder = NodeBuilder.new(
    #     nodes: { "User" => { type: :model, file_path: "app/models/user.rb", namespace: nil } },
    #     positions: { "User" => { "x" => 0, "y" => 0 } },
    #     pagerank: { "User" => 0.05 },
    #     analysis: { hubs: [...], bridges: [...], orphans: [...] },
    #     unit_metadata: { "User" => { "metadata" => { "columns" => [...] } } },
    #     forward_edges: { "User" => ["Post"] },
    #     reverse_edges: { "User" => Set.new(["UsersController"]) }
    #   )
    #   builder.build  # => [{ "id" => "User", "type" => "model", ... }]
    #
    class NodeBuilder
      # Svelte Flow node types mapped from Woods unit types.
      # Unknown types fall back to "default".
      UNIT_TYPE_MAP = {
        model: 'model',
        controller: 'controller',
        service: 'service',
        job: 'job',
        mailer: 'mailer',
        concern: 'concern',
        component: 'component',
        view_component: 'component',
        serializer: 'serializer',
        policy: 'policy',
        validator: 'validator',
        graphql: 'graphql',
        graphql_resolver: 'graphql',
        graphql_mutation: 'graphql',
        graphql_query: 'graphql',
        route: 'route',
        middleware: 'middleware',
        engine: 'engine',
        decorator: 'decorator',
        rake_task: 'rake_task',
        state_machine: 'state_machine',
        event: 'event',
        factory: 'factory',
        rails_source: 'framework',
        gem_source: 'framework'
      }.freeze

      # @param nodes [Hash<String, Hash>] Graph nodes: identifier => { type:, file_path:, namespace: }
      # @param positions [Hash<String, Hash>] Node positions: identifier => { "x" => n, "y" => n }
      # @param pagerank [Hash<String, Float>] PageRank scores
      # @param analysis [Hash] GraphAnalyzer results with :hubs, :bridges, :orphans keys
      # @param unit_metadata [Hash<String, Hash>] Per-unit metadata from extraction output
      # @param forward_edges [Hash<String, Array<String>>] Forward dependency edges
      # @param reverse_edges [Hash<String, Object>] Reverse dependency edges (Sets or Arrays)
      def initialize(nodes:, positions:, pagerank: {}, analysis: {}, unit_metadata: {}, forward_edges: {}, reverse_edges: {})
        @nodes = nodes
        @positions = positions
        @pagerank = pagerank
        @hub_ids = extract_identifiers(analysis[:hubs] || analysis['hubs'])
        @bridge_ids = extract_identifiers(analysis[:bridges] || analysis['bridges'])
        @orphan_ids = Set.new(analysis[:orphans] || analysis['orphans'] || [])
        @unit_metadata = unit_metadata
        @forward_edges = forward_edges
        @reverse_edges = reverse_edges
      end

      # Build Svelte Flow node objects for all graph nodes.
      #
      # @return [Array<Hash>] Svelte Flow node objects
      def build
        @nodes.map do |identifier, meta|
          build_node(identifier, meta)
        end
      end

      private

      # Build a single Svelte Flow node.
      #
      # @param identifier [String] Unit identifier
      # @param meta [Hash] Node metadata with :type, :file_path, :namespace
      # @return [Hash] Svelte Flow node object
      def build_node(identifier, meta)
        unit_type = (meta[:type] || meta['type'])&.to_sym
        position = @positions[identifier] || { 'x' => 0, 'y' => 0 }

        data = {
          'label' => identifier,
          'unitType' => unit_type.to_s,
          'filePath' => meta[:file_path] || meta['file_path'],
          'namespace' => meta[:namespace] || meta['namespace'],
          'pagerank' => @pagerank[identifier] || 0,
          'isHub' => @hub_ids.include?(identifier),
          'isBridge' => @bridge_ids.include?(identifier),
          'isOrphan' => @orphan_ids.include?(identifier),
          'dependencyCount' => (@forward_edges[identifier] || []).size,
          'dependentCount' => (@reverse_edges[identifier] || []).size
        }

        enrich_node_data(data, identifier, unit_type, meta)

        {
          'id' => identifier,
          'type' => UNIT_TYPE_MAP.fetch(unit_type, 'default'),
          'position' => position,
          'data' => data
        }
      end

      # Enrich node data with type-specific columns or attributes.
      #
      # @param data [Hash] The node's data hash (mutated in place)
      # @param identifier [String] Unit identifier
      # @param unit_type [Symbol] The unit type
      # @param meta [Hash] Node metadata from graph
      # @return [void]
      def enrich_node_data(data, identifier, unit_type, meta)
        unit_meta = @unit_metadata[identifier]
        return unless unit_meta

        metadata = unit_meta['metadata'] || unit_meta[:metadata] || {}

        if unit_type == :model
          data['columns'] = build_columns(metadata)
        else
          data['attributes'] = build_attributes(unit_type, metadata, meta)
        end
      end

      # Build the columns array for a model node.
      #
      # @param metadata [Hash] Unit metadata containing columns, primary_key, associations
      # @return [Array<Hash>] Column descriptors
      def build_columns(metadata)
        raw_columns = metadata['columns'] || metadata[:columns] || []
        primary_key = (metadata['primary_key'] || metadata[:primary_key] || 'id').to_s
        foreign_keys = extract_foreign_keys(metadata)

        raw_columns.map do |col|
          name = col['name'] || col[:name]
          {
            'name' => name,
            'type' => normalize_column_type(col['type'] || col[:type]),
            'primary' => name == primary_key,
            'foreign' => foreign_keys.include?(name),
            'nullable' => col['null'] != false && col[:null] != false
          }
        end
      end

      # Extract foreign key column names from associations metadata.
      #
      # @param metadata [Hash] Unit metadata
      # @return [Set<String>] Foreign key column names
      def extract_foreign_keys(metadata)
        associations = metadata['associations'] || metadata[:associations] || []
        fk_names = associations.filter_map do |assoc|
          fk = assoc['foreign_key'] || assoc[:foreign_key]
          fk.to_s if fk
        end
        Set.new(fk_names)
      end

      # Normalize SQL column type to a short display form.
      #
      # @param type_str [String] Raw SQL type (e.g., "character varying(255)")
      # @return [String] Short form (e.g., "varchar")
      def normalize_column_type(type_str)
        return 'unknown' unless type_str

        type_str.to_s
          .sub(/\(.*\)/, '')    # Remove size params
          .sub('character varying', 'varchar')
          .sub('double precision', 'float8')
          .sub('timestamp without time zone', 'timestamp')
          .sub('timestamp with time zone', 'timestamptz')
          .strip
      end

      # Build the attributes array for a non-model node.
      #
      # @param unit_type [Symbol] The unit type
      # @param metadata [Hash] Unit metadata
      # @param meta [Hash] Node metadata from graph (has file_path)
      # @return [Array<String>] Type-specific attribute strings
      def build_attributes(unit_type, metadata, meta)
        case unit_type
        when :controller
          metadata['actions'] || metadata[:actions] || []
        when :job
          queue = metadata['queue'] || metadata[:queue] || 'default'
          ["queue: #{queue}"]
        when :mailer
          metadata['actions'] || metadata[:actions] || []
        when :concern
          metadata['included_by'] || metadata[:included_by] || []
        when :route
          verb = metadata['verb'] || metadata[:verb]
          path = metadata['path'] || metadata[:path]
          verb && path ? ["#{verb} #{path}"] : [file_path_attribute(meta)]
        when :middleware, :engine
          metadata['mount_path'] || metadata[:mount_path] || file_path_attribute(meta)
          [metadata['mount_path'] || metadata[:mount_path] || file_path_attribute(meta)]
        else
          [file_path_attribute(meta)]
        end
      end

      # Extract a relative file path for display.
      #
      # @param meta [Hash] Node metadata
      # @return [String] Relative file path
      def file_path_attribute(meta)
        path = meta[:file_path] || meta['file_path'] || ''
        path.sub(%r{.*/app/}, 'app/')
      end

      # Extract identifier set from hub/bridge analysis arrays.
      #
      # @param items [Array<Hash>, nil] Analysis items with :identifier keys
      # @return [Set<String>]
      def extract_identifiers(items)
        return Set.new unless items

        Set.new(items.map { |h| h[:identifier] || h['identifier'] })
      end
    end
  end
end
```

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/svelte_flow/node_builder_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: ALL PASS (existing specs + new specs)

- [ ] **Step 5: Commit**

```bash
git add spec/svelte_flow/node_builder_spec.rb lib/woods/svelte_flow/node_builder.rb
git commit -m "Enrich NodeBuilder with columns, attributes, and dependency counts"
```

---

## Task 2: Update Transformer to load unit metadata and clean up symbol fallbacks

**Context:** The `Transformer` orchestrates node/edge building. It needs to: (1) accept a `unit_metadata` hash and pass it to `NodeBuilder`, (2) pass forward/reverse edges for dependency counts, (3) clean up the `step[:unit] || step['unit']` anti-pattern — since `JSON.parse` always produces string keys, symbol fallbacks are dead code.

**Files:**
- Modify: `spec/svelte_flow/transformer_spec.rb`
- Modify: `lib/woods/svelte_flow/transformer.rb`

- [ ] **Step 1: Write failing specs for enriched node output and dependency counts**

Add to `spec/svelte_flow/transformer_spec.rb`:

```ruby
describe '#dependency_graph_data with unit metadata' do
  let(:unit_metadata) do
    {
      'User' => {
        'metadata' => {
          'primary_key' => 'id',
          'columns' => [
            { 'name' => 'id', 'type' => 'bigint', 'null' => false },
            { 'name' => 'name', 'type' => 'varchar', 'null' => false }
          ],
          'associations' => []
        }
      },
      'UsersController' => {
        'metadata' => {
          'actions' => %w[index show]
        }
      }
    }
  end

  subject { described_class.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata) }

  let(:result) { subject.dependency_graph_data }

  it 'includes columns on model nodes' do
    user = result['nodes'].find { |n| n['id'] == 'User' }
    expect(user['data']['columns']).to be_an(Array)
    expect(user['data']['columns'].first['name']).to eq('id')
  end

  it 'includes attributes on controller nodes' do
    controller = result['nodes'].find { |n| n['id'] == 'UsersController' }
    expect(controller['data']['attributes']).to eq(%w[index show])
  end

  it 'includes dependency counts on all nodes' do
    user = result['nodes'].find { |n| n['id'] == 'User' }
    expect(user['data']).to have_key('dependencyCount')
    expect(user['data']).to have_key('dependentCount')
  end
end
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/svelte_flow/transformer_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: FAIL — `ArgumentError: unknown keyword: :unit_metadata`

- [ ] **Step 3: Implement Transformer changes**

Replace the full `lib/woods/svelte_flow/transformer.rb`:

```ruby
# frozen_string_literal: true

require_relative 'node_builder'
require_relative 'edge_builder'

module Woods
  module SvelteFlow
    # Orchestrates conversion of Woods extraction data into Svelte Flow format.
    #
    # Takes a DependencyGraph, GraphAnalyzer, and optional unit metadata,
    # and produces Svelte Flow-compatible hashes with nodes and edges arrays.
    # Does NOT perform I/O — callers handle reading/writing.
    #
    # @example
    #   transformer = Transformer.new(graph: graph, analyzer: analyzer)
    #   data = transformer.dependency_graph_data
    #   # => { "nodes" => [...], "edges" => [...] }
    #
    class Transformer # rubocop:disable Metrics/ClassLength
      # @param graph [DependencyGraph] The dependency graph
      # @param analyzer [GraphAnalyzer] Graph analyzer for structural enrichment
      # @param unit_metadata [Hash<String, Hash>] Per-unit metadata from extraction output
      def initialize(graph:, analyzer:, unit_metadata: {})
        @graph = graph
        @analyzer = analyzer
        @unit_metadata = unit_metadata
      end

      # Convert the full dependency graph into Svelte Flow format.
      #
      # @return [Hash] { "nodes" => Array, "edges" => Array }
      def dependency_graph_data # rubocop:disable Metrics/MethodLength
        graph_data = @graph.to_h
        nodes = graph_data[:nodes] || graph_data['nodes'] || {}
        edges = graph_data[:edges] || graph_data['edges'] || {}
        reverse = graph_data[:reverse] || graph_data['reverse'] || {}
        pagerank_scores = @graph.pagerank

        analysis = build_analysis
        cycle_edges = build_cycle_edge_set(analysis[:cycles] || [])

        node_builder = NodeBuilder.new(
          nodes: nodes,
          positions: {},
          pagerank: pagerank_scores,
          analysis: analysis,
          unit_metadata: @unit_metadata,
          forward_edges: edges,
          reverse_edges: reverse
        )

        valid_ids = Set.new(nodes.keys)
        edge_builder = EdgeBuilder.new(
          edges: edges,
          valid_node_ids: valid_ids,
          cycle_edges: cycle_edges
        )

        {
          'nodes' => node_builder.build,
          'edges' => edge_builder.build
        }
      end

      # Convert a flow document into Svelte Flow format.
      #
      # @param flow_data [Hash] Serialized FlowDocument (from FlowDocument#to_h or JSON)
      # @return [Hash] { "nodes" => Array, "edges" => Array, "metadata" => Hash }
      def flow_data(flow_data) # rubocop:disable Metrics
        steps = flow_data['steps'] || []

        flow_nodes = []
        seen = Set.new
        step_index = 0

        steps.each do |step|
          unit = step['unit']
          next unless unit
          next if seen.include?(unit)

          seen.add(unit)
          step_type = step['type']
          operations = step['operations'] || []

          flow_nodes << {
            'id' => unit,
            'type' => 'flow_step',
            'position' => { 'x' => 0, 'y' => step_index * 150 },
            'data' => {
              'label' => unit,
              'stepType' => step_type.to_s,
              'filePath' => step['file_path'],
              'operationCount' => operations.size,
              'operations' => summarize_operations(operations)
            }
          }
          step_index += 1
        end

        flow_edges = EdgeBuilder.flow_edges(steps)

        {
          'nodes' => flow_nodes,
          'edges' => flow_edges,
          'metadata' => {
            'entryPoint' => flow_data['entry_point'],
            'route' => flow_data['route'],
            'maxDepth' => flow_data['max_depth']
          }
        }
      end

      # Convert domain clusters into Svelte Flow format.
      #
      # @return [Hash] { "nodes" => Array, "edges" => Array, "clusters" => Array }
      def domain_cluster_data # rubocop:disable Metrics
        clusters = @analyzer.domain_clusters
        return { 'nodes' => [], 'edges' => [], 'clusters' => [] } if clusters.empty?

        graph_data = @graph.to_h
        edges = graph_data[:edges] || graph_data['edges'] || {}
        reverse = graph_data[:reverse] || graph_data['reverse'] || {}
        nodes = graph_data[:nodes] || graph_data['nodes'] || {}
        pagerank_scores = @graph.pagerank

        analysis = build_analysis

        cluster_member_ids = clusters.flat_map { |c| c[:members] || c['members'] || [] }
        cluster_nodes = nodes.slice(*cluster_member_ids)

        node_builder = NodeBuilder.new(
          nodes: cluster_nodes,
          positions: {},
          pagerank: pagerank_scores,
          analysis: analysis,
          unit_metadata: @unit_metadata,
          forward_edges: edges,
          reverse_edges: reverse
        )

        all_boundary_edges = clusters.flat_map { |c| c[:boundary_edges] || c['boundary_edges'] || [] }
        valid_ids = Set.new(cluster_member_ids)

        boundary = EdgeBuilder.boundary_edges(all_boundary_edges, valid_node_ids: valid_ids)

        intra_edges = cluster_member_ids.each_with_object({}) do |id, h|
          targets = (edges[id] || []) & cluster_member_ids
          h[id] = targets unless targets.empty?
        end
        intra_edge_builder = EdgeBuilder.new(edges: intra_edges, valid_node_ids: valid_ids)

        cluster_summaries = clusters.map do |c|
          {
            'name' => c[:name] || c['name'],
            'hub' => c[:hub] || c['hub'],
            'memberCount' => c[:member_count] || c['member_count'],
            'entryPoints' => c[:entry_points] || c['entry_points'] || [],
            'types' => c[:types] || c['types'] || {}
          }
        end

        {
          'nodes' => node_builder.build,
          'edges' => intra_edge_builder.build + boundary,
          'clusters' => cluster_summaries
        }
      end

      # Export all visualization types in a single wrapper.
      #
      # @param flow_documents [Array<Hash>] Optional flow documents to include
      # @return [Hash] Combined export with dependency_graph, flows, and clusters
      def full_export(flow_documents: [])
        result = {
          'dependency_graph' => dependency_graph_data,
          'domain_clusters' => domain_cluster_data,
          'flows' => {}
        }

        flow_documents.each do |doc|
          entry = doc['entry_point']
          result['flows'][entry] = flow_data(doc) if entry
        end

        result
      end

      private

      # Build analysis data from the GraphAnalyzer.
      #
      # @return [Hash] Analysis results
      def build_analysis
        @build_analysis ||= {
          hubs: @analyzer.hubs,
          bridges: @analyzer.bridges(limit: 20),
          orphans: @analyzer.orphans,
          cycles: @analyzer.cycles
        }
      end

      # Build a set of cycle edge pairs for marking in the edge builder.
      #
      # @param cycles [Array<Array<String>>] Cycle paths from GraphAnalyzer
      # @return [Set<Array<String>>] Set of [source, target] pairs
      def build_cycle_edge_set(cycles)
        cycle_edges = Set.new
        cycles.each do |cycle|
          cycle.each_cons(2) { |a, b| cycle_edges.add([a, b]) }
        end
        cycle_edges
      end

      # Summarize operations for a flow step node's data.
      #
      # @param operations [Array<Hash>] Operations from a flow step
      # @return [Array<Hash>] Simplified operation summaries
      def summarize_operations(operations)
        operations.map do |op|
          {
            'type' => (op['type']).to_s,
            'target' => op['target'],
            'method' => op['method'],
            'line' => op['line']
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Update existing transformer specs for string-only keys**

The `flow_data` and `full_export` specs use symbol keys in test fixtures. Update them to use string keys since the symbol fallbacks are now removed:

In `spec/svelte_flow/transformer_spec.rb`, change the `flow_doc` let block:

```ruby
let(:flow_doc) do
  {
    'entry_point' => 'UsersController#create',
    'route' => { 'verb' => 'POST', 'path' => '/users' },
    'max_depth' => 5,
    'steps' => [
      { 'unit' => 'UsersController#create', 'type' => 'controller', 'file_path' => 'app/controllers/users_controller.rb',
        'operations' => [{ 'type' => 'call', 'target' => 'UserService', 'method' => 'call', 'line' => 10 }] },
      { 'unit' => 'UserService', 'type' => 'service', 'file_path' => 'app/services/user_service.rb',
        'operations' => [{ 'type' => 'call', 'target' => 'User', 'method' => 'create!', 'line' => 5 }] }
    ]
  }
end
```

Update the deduplication test fixture:

```ruby
it 'deduplicates nodes for repeated units' do
  doc = {
    'entry_point' => 'A',
    'steps' => [{ 'unit' => 'A', 'type' => 'x', 'operations' => [] }, { 'unit' => 'B', 'type' => 'y', 'operations' => [] },
                { 'unit' => 'A', 'type' => 'x', 'operations' => [] }]
  }
  result = subject.flow_data(doc)
  ids = result['nodes'].map { |n| n['id'] }
  expect(ids.uniq.size).to eq(ids.size)
end
```

Update the `full_export` test:

```ruby
it 'includes flow documents when provided' do
  flow = {
    'entry_point' => 'TestController#index',
    'steps' => [{ 'unit' => 'TestController#index', 'type' => 'controller', 'operations' => [] }]
  }
  result = subject.full_export(flow_documents: [flow])

  expect(result['flows']).to have_key('TestController#index')
end
```

Update the `flow_data` metadata expectation to use string keys:

```ruby
it 'includes metadata about the flow' do
  expect(result['metadata']['entryPoint']).to eq('UsersController#create')
  expect(result['metadata']['route']).to eq({ 'verb' => 'POST', 'path' => '/users' })
end
```

- [ ] **Step 5: Run specs to verify they pass**

Run: `bundle exec rspec spec/svelte_flow/transformer_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add spec/svelte_flow/transformer_spec.rb lib/woods/svelte_flow/transformer.rb
git commit -m "Enrich Transformer with unit metadata, clean up symbol-or-string fallbacks"
```

---

## Task 3: Update Exporter to load and pass unit metadata

**Context:** The `Exporter` reads from the extraction output directory. It needs to load the per-unit metadata from the type directories and pass it to the Transformer so nodes get enriched with columns/attributes.

**Files:**
- Modify: `spec/svelte_flow/exporter_spec.rb`
- Modify: `lib/woods/svelte_flow/exporter.rb`

- [ ] **Step 1: Write failing spec for unit metadata loading**

Add to `spec/svelte_flow/exporter_spec.rb`:

```ruby
describe '#load_unit_metadata' do
  it 'loads metadata from type directory index files' do
    # Create a mock type directory with _index.json
    model_dir = File.join(index_dir, 'model')
    FileUtils.mkdir_p(model_dir)

    unit_data = {
      'type' => 'model',
      'identifier' => 'User',
      'metadata' => {
        'primary_key' => 'id',
        'columns' => [{ 'name' => 'id', 'type' => 'bigint', 'null' => false }],
        'associations' => []
      }
    }
    File.write(File.join(model_dir, 'User_abcd1234.json'), JSON.generate(unit_data))

    exporter = described_class.new(index_dir: index_dir)
    metadata = exporter.send(:load_unit_metadata)

    expect(metadata).to have_key('User')
    expect(metadata['User']['metadata']['columns']).to be_an(Array)
  end
end
```

Note: This test depends on the existing test setup in `exporter_spec.rb` that creates a temporary `index_dir` with a `manifest.json`. Read the existing spec to find the `let(:index_dir)` pattern and match it.

- [ ] **Step 2: Run spec to verify it fails**

Run: `bundle exec rspec spec/svelte_flow/exporter_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: FAIL — `NoMethodError: undefined method 'load_unit_metadata'`

- [ ] **Step 3: Implement Exporter changes**

Add the `load_unit_metadata` private method to `lib/woods/svelte_flow/exporter.rb`:

```ruby
# Load per-unit metadata from extraction output type directories.
#
# Scans each type subdirectory for individual unit JSON files (not _index.json)
# and extracts identifier + metadata for NodeBuilder enrichment.
#
# @return [Hash<String, Hash>] identifier => { "metadata" => Hash }
def load_unit_metadata
  metadata = {}

  Dir.glob(File.join(@index_dir, '*')).each do |type_dir|
    next unless File.directory?(type_dir)
    next if File.basename(type_dir) == 'svelte_flow'
    next if File.basename(type_dir) == 'flows'

    Dir.glob(File.join(type_dir, '*.json')).each do |unit_file|
      next if File.basename(unit_file) == '_index.json'

      unit_data = JSON.parse(File.read(unit_file))
      identifier = unit_data['identifier'] || unit_data[:identifier]
      next unless identifier

      metadata[identifier.to_s] = unit_data
    rescue JSON::ParserError
      next
    end
  end

  metadata
end
```

Update `build_transformer` to pass unit metadata:

```ruby
def build_transformer
  graph = load_graph
  analyzer = GraphAnalyzer.new(graph)
  unit_metadata = load_unit_metadata
  Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)
end
```

Update `export_all` similarly — the transformer is built inline there:

```ruby
def export_all # rubocop:disable Metrics/MethodLength
  graph = load_graph
  analyzer = GraphAnalyzer.new(graph)
  unit_metadata = load_unit_metadata
  transformer = Transformer.new(graph: graph, analyzer: analyzer, unit_metadata: unit_metadata)
  # ... rest unchanged
```

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/svelte_flow/exporter_spec.rb --format progress --format json --out tmp/test_results.json`
Expected: ALL PASS

- [ ] **Step 5: Run full svelte_flow spec suite**

Run: `bundle exec rspec spec/svelte_flow/ --format progress --format json --out tmp/test_results.json`
Expected: ALL PASS

- [ ] **Step 6: Commit**

```bash
git add spec/svelte_flow/exporter_spec.rb lib/woods/svelte_flow/exporter.rb
git commit -m "Load unit metadata in Exporter for node enrichment"
```

---

## Task 4: Update theme.js with spec colors and add highlight CSS variables

**Context:** The spec defines specific type colors (some differ from current theme) and adds highlight/dim CSS. The theme needs updating to match the spec's color palette, and `app.css` needs new CSS custom properties for highlight states.

**Files:**
- Modify: `frontend/src/lib/theme.js`
- Modify: `frontend/src/app.css`

- [ ] **Step 1: Update theme.js type colors**

Replace `frontend/src/lib/theme.js`:

```javascript
export const TYPE_COLORS = {
  model: { bg: '#1e3a5f', border: '#3b82f6', text: '#93c5fd' },
  controller: { bg: '#1a3b2a', border: '#22c55e', text: '#86efac' },
  service: { bg: '#2a1a3b', border: '#a855f7', text: '#d8b4fe' },
  job: { bg: '#3b2e1a', border: '#f59e0b', text: '#fcd34d' },
  mailer: { bg: '#3b1a2e', border: '#ec4899', text: '#f9a8d4' },
  concern: { bg: '#1a3b3b', border: '#06b6d4', text: '#67e8f9' },
  component: { bg: '#1a3b3b', border: '#14b8a6', text: '#5eead4' },
  graphql: { bg: '#3b1a3b', border: '#e11d48', text: '#fda4af' },
  serializer: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  policy: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  route: { bg: '#2a3b1a', border: '#84cc16', text: '#bef264' },
  middleware: { bg: '#3b2a1a', border: '#f97316', text: '#fdba74' },
  engine: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  decorator: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  rake_task: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  state_machine: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  event: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  factory: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  framework: { bg: '#27272a', border: '#71717a', text: '#a1a1aa' },
  flow_step: { bg: '#1e293b', border: '#0ea5e9', text: '#7dd3fc' },
  default: { bg: '#1e293b', border: '#475569', text: '#94a3b8' },
};

/** Sidebar-friendly dot color (just the border color for the type dot). */
export const TYPE_DOT_COLORS = Object.fromEntries(
  Object.entries(TYPE_COLORS).map(([k, v]) => [k, v.border])
);

/** Display names for type groups in the sidebar. */
export const TYPE_DISPLAY_NAMES = {
  model: 'Models',
  controller: 'Controllers',
  job: 'Jobs',
  service: 'Services',
  mailer: 'Mailers',
  concern: 'Concerns',
  middleware: 'Middleware',
  route: 'Routes',
  component: 'Components',
  graphql: 'GraphQL',
  serializer: 'Serializers',
  policy: 'Policies',
  decorator: 'Decorators',
  rake_task: 'Rake Tasks',
  engine: 'Engines',
  event: 'Events',
  factory: 'Factories',
  framework: 'Framework',
  state_machine: 'State Machines',
  validator: 'Validators',
};

export function getTypeColor(type) {
  return TYPE_COLORS[type] || TYPE_COLORS.default;
}

export function getTypeDisplayName(type) {
  return TYPE_DISPLAY_NAMES[type] || type.charAt(0).toUpperCase() + type.slice(1).replace(/_/g, ' ');
}
```

- [ ] **Step 2: Update app.css with sidebar, highlight, and layout styles**

Replace `frontend/src/app.css`:

```css
:root {
  --bg-primary: #0f172a;
  --bg-secondary: #1e293b;
  --bg-tertiary: #334155;
  --text-primary: #e2e8f0;
  --text-secondary: #94a3b8;
  --border: #475569;
  --border-subtle: #334155;
  --accent: #3b82f6;
  --highlight: #22c55e;
  --highlight-glow: rgba(34, 197, 94, 0.3);
  --highlight-glow-subtle: rgba(34, 197, 94, 0.2);
}

* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  background: var(--bg-primary);
  color: var(--text-primary);
  height: 100vh;
  overflow: hidden;
}

#app {
  display: grid;
  grid-template-columns: 240px 1fr;
  grid-template-rows: 48px 1fr 32px;
  height: 100vh;
}

/* ── Header ─────────────────────────────────────────────── */

.header {
  grid-column: 1 / -1;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 16px;
  background: var(--bg-secondary);
  border-bottom: 1px solid var(--border);
}

.header h1 {
  font-size: 14px;
  font-weight: 600;
}

.header h1 span {
  color: var(--text-secondary);
  font-weight: 400;
}

.tabs {
  display: flex;
  gap: 4px;
}

.tab {
  padding: 6px 12px;
  border: none;
  background: none;
  color: var(--text-secondary);
  font-size: 12px;
  cursor: pointer;
  border-radius: 4px;
}

.tab:hover {
  background: var(--bg-tertiary);
}

.tab:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.tab.active {
  background: var(--accent);
  color: #fff;
}

/* ── Left Sidebar ───────────────────────────────────────── */

.sidebar-panel {
  grid-row: 2 / 4;
  background: var(--bg-secondary);
  border-right: 1px solid var(--border);
  display: flex;
  flex-direction: column;
  overflow: hidden;
}

.sidebar-header {
  padding: 12px;
  border-bottom: 1px solid var(--border-subtle);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.sidebar-header-title {
  font-weight: 600;
  font-size: 13px;
}

.sidebar-header-count {
  color: var(--text-secondary);
  font-size: 11px;
}

.filter-input {
  margin: 8px 12px;
  padding: 6px 8px;
  background: var(--bg-tertiary);
  border: 1px solid var(--border);
  border-radius: 4px;
  color: var(--text-primary);
  font-size: 11px;
  outline: none;
}

.filter-input::placeholder {
  color: var(--text-secondary);
}

.filter-input:focus {
  border-color: var(--accent);
}

.bulk-actions {
  padding: 4px 12px 8px;
  display: flex;
  justify-content: flex-end;
  gap: 4px;
  font-size: 10px;
}

.bulk-actions button {
  background: none;
  border: none;
  color: var(--accent);
  cursor: pointer;
  padding: 2px 4px;
}

.bulk-actions button:hover {
  text-decoration: underline;
}

.bulk-actions button:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}

.bulk-actions-divider {
  color: var(--border);
}

.sidebar-list {
  overflow-y: auto;
  flex: 1;
  padding: 0 8px 8px;
}

/* ── Type Group ─────────────────────────────────────────── */

.type-group {
  margin-bottom: 2px;
}

.type-group-header {
  padding: 6px 8px;
  font-size: 11px;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 6px;
  cursor: pointer;
  border-radius: 4px;
  border: none;
  background: none;
  color: var(--text-primary);
  width: 100%;
  text-align: left;
}

.type-group-header:hover {
  background: var(--bg-tertiary);
}

.type-group-header:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: -2px;
}

.type-group-chevron {
  color: var(--text-secondary);
  font-size: 10px;
  width: 12px;
  flex-shrink: 0;
}

.type-group-dot {
  width: 8px;
  height: 8px;
  border-radius: 2px;
  flex-shrink: 0;
}

.type-group-count {
  color: var(--text-secondary);
  margin-left: auto;
  font-weight: 400;
}

/* ── Unit Item ──────────────────────────────────────────── */

.unit-item {
  padding: 4px 8px 4px 28px;
  font-size: 11px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  border-radius: 3px;
  cursor: pointer;
  color: var(--text-secondary);
}

.unit-item:hover {
  background: var(--bg-tertiary);
}

.unit-item.active {
  background: rgba(59, 130, 246, 0.12);
  color: var(--text-primary);
}

.unit-item-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  flex: 1;
  min-width: 0;
}

.visibility-toggle {
  background: none;
  border: none;
  cursor: pointer;
  padding: 2px;
  font-size: 12px;
  line-height: 1;
  color: var(--text-secondary);
  opacity: 0.6;
  flex-shrink: 0;
}

.visibility-toggle.visible {
  opacity: 1;
}

.visibility-toggle:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 1px;
}

/* ── Main Content ───────────────────────────────────────── */

.main-content {
  position: relative;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

.flow-container {
  position: relative;
  overflow: hidden;
  flex: 1;
  min-height: 0;
}

/* ── Stats Bar ──────────────────────────────────────────── */

.stats-bar {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 0 16px;
  background: var(--bg-secondary);
  border-top: 1px solid var(--border);
  font-size: 11px;
  color: var(--text-secondary);
}

.stat-value {
  color: var(--text-primary);
  font-weight: 600;
}

/* ── Right Detail Panel ─────────────────────────────────── */

.detail-panel {
  position: absolute;
  right: 0;
  top: 0;
  bottom: 0;
  width: 280px;
  background: var(--bg-secondary);
  border-left: 1px solid var(--border);
  transform: translateX(100%);
  transition: transform 0.2s;
  overflow-y: auto;
  z-index: 10;
  display: flex;
  flex-direction: column;
}

.detail-panel.open {
  transform: translateX(0);
}

.detail-panel-header {
  padding: 12px;
  border-bottom: 1px solid var(--border-subtle);
  display: flex;
  justify-content: space-between;
  align-items: center;
}

.detail-panel-header h3 {
  font-size: 14px;
  word-break: break-all;
}

.detail-panel-body {
  padding: 12px;
  flex: 1;
  overflow-y: auto;
}

.detail-row {
  display: flex;
  justify-content: space-between;
  padding: 6px 0;
  border-bottom: 1px solid var(--bg-tertiary);
  font-size: 12px;
}

.detail-label {
  color: var(--text-secondary);
}

.detail-value {
  color: var(--text-primary);
  text-align: right;
  max-width: 60%;
  word-break: break-all;
}

.close-btn {
  background: none;
  border: none;
  color: var(--text-secondary);
  font-size: 18px;
  cursor: pointer;
  padding: 2px 6px;
}

.close-btn:hover {
  color: var(--text-primary);
}

.close-btn:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

/* ── Node Highlight/Dim ─────────────────────────────────── */

.node-active {
  border: 2px solid var(--highlight) !important;
  box-shadow: 0 0 20px var(--highlight-glow);
}

.node-highlighted {
  border: 1px solid var(--highlight) !important;
  box-shadow: 0 0 12px var(--highlight-glow-subtle);
}

.node-dimmed {
  opacity: 0.4;
}

/* ── Loading/Error ──────────────────────────────────────── */

.loading-overlay {
  display: flex;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: var(--text-secondary);
  font-size: 14px;
  gap: 8px;
}

.error-overlay {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  height: 100%;
  color: #ef4444;
  font-size: 14px;
  gap: 8px;
}

/* ── Svelte Flow overrides ──────────────────────────────── */

.svelte-flow {
  background: var(--bg-primary) !important;
}

.svelte-flow__minimap {
  background: var(--bg-secondary) !important;
  border: 1px solid var(--border) !important;
}

.svelte-flow__controls {
  border: 1px solid var(--border) !important;
}

.svelte-flow__controls button {
  background: var(--bg-secondary) !important;
  border-color: var(--border) !important;
  color: var(--text-primary) !important;
}

.svelte-flow__controls button:hover {
  background: var(--bg-tertiary) !important;
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/theme.js frontend/src/app.css
git commit -m "Update theme colors and add sidebar/highlight CSS styles"
```

---

## Task 5: Create ModelNode and CompactNode components

**Context:** These replace `WoodsNode.svelte`. `ModelNode` renders model units with a header row and column rows (with borders between). `CompactNode` renders all other units with a header and type-specific attributes. Both support highlight/dim via CSS classes driven by `data.isActive`, `data.isHighlighted` flags.

**Files:**
- Create: `frontend/src/components/ModelNode.svelte`
- Create: `frontend/src/components/CompactNode.svelte`

- [ ] **Step 1: Create ModelNode.svelte**

Create `frontend/src/components/ModelNode.svelte`:

```svelte
<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType || 'model'));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 24 ? label.slice(0, 22) + '...' : label
  );
  const columns = $derived(data?.columns || []);
  const highlightClass = $derived(
    data?.isActive ? 'node-active' :
    data?.isHighlighted ? 'node-highlighted' :
    data?.isActive === false && data?.isHighlighted === false ? 'node-dimmed' : ''
  );
</script>

<div
  class="model-node {highlightClass}"
  style="border-color:{colors.border};"
>
  <Handle type="target" position={targetPosition || Position.Top} />

  <div class="model-header" style="border-bottom-color:{colors.border}40;">
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="model-name">{truncated}</span>
    {#if data?.isHub}
      <span class="role-badge">HUB</span>
    {:else if data?.isBridge}
      <span class="role-badge">BRG</span>
    {/if}
  </div>

  {#if columns.length > 0}
    <div class="model-columns">
      {#each columns as col, i}
        <div class="model-column" class:column-border={i > 0}>
          <span class="column-key">
            {#if col.primary}
              <span class="key-icon" title="Primary key">&#x1F511;</span>
            {:else if col.foreign}
              <span class="key-icon" title="Foreign key">&#x1F517;</span>
            {:else if !col.nullable}
              <span class="key-icon" title="Required">&#x25C6;</span>
            {:else}
              <span class="key-icon" title="Optional">&#x25C7;</span>
            {/if}
            {col.name}
          </span>
          <span class="column-type">{col.type}</span>
        </div>
      {/each}
    </div>
  {/if}

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .model-node {
    background: var(--bg-secondary);
    border: 1px solid;
    border-radius: 6px;
    min-width: 160px;
    max-width: 220px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  }

  .model-header {
    padding: 8px 12px;
    display: flex;
    align-items: center;
    gap: 6px;
    border-bottom: 1px solid;
  }

  .type-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .model-name {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  .role-badge {
    font-size: 9px;
    font-weight: 600;
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .model-columns {
    padding: 2px 0;
  }

  .model-column {
    padding: 3px 12px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    font-size: 10px;
  }

  .column-border {
    border-top: 1px solid var(--border-subtle);
  }

  .column-key {
    color: var(--text-secondary);
    display: flex;
    align-items: center;
    gap: 3px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .key-icon {
    font-size: 9px;
    flex-shrink: 0;
  }

  .column-type {
    color: var(--text-secondary);
    opacity: 0.7;
    font-size: 9px;
    flex-shrink: 0;
    margin-left: 8px;
  }
</style>
```

- [ ] **Step 2: Create CompactNode.svelte**

Create `frontend/src/components/CompactNode.svelte`:

```svelte
<script>
  import { Handle, Position } from '@xyflow/svelte';
  import { getTypeColor } from '../lib/theme.js';

  let { data, sourcePosition, targetPosition } = $props();

  const colors = $derived(getTypeColor(data?.unitType || 'default'));
  const label = $derived(data?.label || '');
  const truncated = $derived(
    label.length > 24 ? label.slice(0, 22) + '...' : label
  );
  const attributes = $derived(data?.attributes || []);
  const highlightClass = $derived(
    data?.isActive ? 'node-active' :
    data?.isHighlighted ? 'node-highlighted' :
    data?.isActive === false && data?.isHighlighted === false ? 'node-dimmed' : ''
  );
</script>

<div
  class="compact-node {highlightClass}"
  style="border-color:{colors.border};"
>
  <Handle type="target" position={targetPosition || Position.Top} />

  <div class="compact-header" style="border-bottom-color:{colors.border}40;">
    <span class="type-dot" style="background:{colors.border};"></span>
    <span class="compact-name">{truncated}</span>
    {#if data?.isHub}
      <span class="role-badge">HUB</span>
    {:else if data?.isBridge}
      <span class="role-badge">BRG</span>
    {/if}
  </div>

  {#if attributes.length > 0}
    <div class="compact-attributes">
      <div class="attribute-row">
        {attributes.join(', ')}
      </div>
    </div>
  {/if}

  <Handle type="source" position={sourcePosition || Position.Bottom} />
</div>

<style>
  .compact-node {
    background: var(--bg-secondary);
    border: 1px solid;
    border-radius: 6px;
    min-width: 130px;
    max-width: 200px;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
  }

  .compact-header {
    padding: 8px 12px;
    display: flex;
    align-items: center;
    gap: 6px;
    border-bottom: 1px solid;
  }

  .type-dot {
    width: 8px;
    height: 8px;
    border-radius: 2px;
    flex-shrink: 0;
  }

  .compact-name {
    font-size: 12px;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    flex: 1;
  }

  .role-badge {
    font-size: 9px;
    font-weight: 600;
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .compact-attributes {
    padding: 4px 12px 6px;
  }

  .attribute-row {
    font-size: 10px;
    color: var(--text-secondary);
    line-height: 1.4;
    word-break: break-word;
  }
</style>
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/ModelNode.svelte frontend/src/components/CompactNode.svelte
git commit -m "Add ModelNode and CompactNode components for enriched node rendering"
```

---

## Task 6: Create Sidebar and TypeGroup components

**Context:** The sidebar is the main navigation tool. It has a filter input, bulk show/hide, and collapsible type groups. Each unit shows a name (click to select) and an eye toggle (click to show/hide on canvas). ALT+Click on a unit name triggers focus mode.

**Files:**
- Create: `frontend/src/components/TypeGroup.svelte`
- Create: `frontend/src/components/Sidebar.svelte`

- [ ] **Step 1: Create TypeGroup.svelte**

Create `frontend/src/components/TypeGroup.svelte`:

```svelte
<script>
  import { getTypeDisplayName } from '../lib/theme.js';

  let {
    unitType,
    units,
    dotColor,
    collapsed,
    activeNodeId,
    visibleNodeIds,
    onToggleCollapse,
    onSelectUnit,
    onToggleVisibility,
    onFocusUnit,
  } = $props();

  const displayName = $derived(getTypeDisplayName(unitType));
</script>

<div class="type-group">
  <button
    class="type-group-header"
    onclick={onToggleCollapse}
    aria-expanded={!collapsed}
  >
    <span class="type-group-chevron">{collapsed ? '\u25B6' : '\u25BC'}</span>
    <span class="type-group-dot" style="background:{dotColor};"></span>
    {displayName}
    <span class="type-group-count">{units.length}</span>
  </button>

  {#if !collapsed}
    {#each units as unit}
      <div
        class="unit-item"
        class:active={activeNodeId === unit.id}
        role="button"
        tabindex="0"
        onclick={(e) => {
          if (e.altKey) {
            onFocusUnit?.(unit.id);
          } else {
            onSelectUnit?.(unit.id);
          }
        }}
        onkeydown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onSelectUnit?.(unit.id);
          }
        }}
      >
        <span class="unit-item-name" title={unit.data?.label || unit.id}>
          {unit.data?.label || unit.id}
        </span>
        <button
          class="visibility-toggle"
          class:visible={visibleNodeIds.has(unit.id)}
          title={visibleNodeIds.has(unit.id) ? 'Hide from canvas' : 'Show on canvas'}
          onclick|stopPropagation={(e) => {
            e.stopPropagation();
            onToggleVisibility?.(unit.id);
          }}
          aria-label="{visibleNodeIds.has(unit.id) ? 'Hide' : 'Show'} {unit.data?.label || unit.id}"
        >
          {visibleNodeIds.has(unit.id) ? '\u{1F441}' : '\u{1F441}\u{FE0F}\u{200D}\u{1F5E8}\u{FE0F}'}
        </button>
      </div>
    {/each}
  {/if}
</div>
```

Note: The eye icon uses Unicode characters. The "visible" state shows the eye (&#x1F441;). The "hidden" state uses a different indicator. If the Unicode rendering is problematic, the implementer should use simple text: "Show" / "Hide" or SVG icons. The functional behavior is what matters.

- [ ] **Step 2: Create Sidebar.svelte**

Create `frontend/src/components/Sidebar.svelte`:

```svelte
<script>
  import TypeGroup from './TypeGroup.svelte';
  import { TYPE_DOT_COLORS } from '../lib/theme.js';

  let {
    allNodes,
    activeNodeId,
    visibleNodeIds,
    filterText = $bindable(''),
    collapsedTypes,
    onSelectUnit,
    onToggleVisibility,
    onFocusUnit,
    onToggleCollapse,
    onShowAll,
    onHideAll,
  } = $props();

  const visibleCount = $derived(visibleNodeIds.size);
  const totalCount = $derived(allNodes.length);

  const filteredNodes = $derived(
    filterText
      ? allNodes.filter((n) =>
          (n.data?.label || n.id).toLowerCase().includes(filterText.toLowerCase())
        )
      : allNodes
  );

  const groupedUnits = $derived.by(() => {
    const groups = {};
    for (const node of filteredNodes) {
      const type = node.data?.unitType || 'default';
      if (!groups[type]) groups[type] = [];
      groups[type].push(node);
    }
    // Sort groups: models first, then alphabetically
    const sortOrder = ['model', 'controller', 'job', 'service', 'mailer', 'concern'];
    return Object.entries(groups).sort(([a], [b]) => {
      const ai = sortOrder.indexOf(a);
      const bi = sortOrder.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    });
  });
</script>

<aside class="sidebar-panel">
  <div class="sidebar-header">
    <span class="sidebar-header-title">Units</span>
    <span class="sidebar-header-count">{visibleCount}/{totalCount} visible</span>
  </div>

  <input
    class="filter-input"
    type="text"
    placeholder="Filter units..."
    bind:value={filterText}
    aria-label="Filter units by name"
  />

  <div class="bulk-actions">
    <button onclick={onShowAll}>Show All</button>
    <span class="bulk-actions-divider">|</span>
    <button onclick={onHideAll}>Hide All</button>
  </div>

  <div class="sidebar-list">
    {#each groupedUnits as [type, units], i}
      <TypeGroup
        unitType={type}
        {units}
        dotColor={TYPE_DOT_COLORS[type] || '#475569'}
        collapsed={collapsedTypes.has(type)}
        {activeNodeId}
        {visibleNodeIds}
        {onSelectUnit}
        {onToggleVisibility}
        {onFocusUnit}
        onToggleCollapse={() => onToggleCollapse?.(type)}
      />
    {/each}
  </div>
</aside>
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/TypeGroup.svelte frontend/src/components/Sidebar.svelte
git commit -m "Add Sidebar and TypeGroup components for unit browsing"
```

---

## Task 7: Update layout.js for dynamic node heights

**Context:** The current layout uses fixed `NODE_HEIGHT = 44`. With column rows on model nodes, heights vary. The layout function needs to accept per-node height calculations based on content.

**Files:**
- Modify: `frontend/src/lib/layout.js`

- [ ] **Step 1: Update layout.js**

Replace `frontend/src/lib/layout.js`:

```javascript
import dagre from '@dagrejs/dagre';

const NODE_WIDTH = 200;
const BASE_NODE_HEIGHT = 44;
const COLUMN_ROW_HEIGHT = 20;
const ATTRIBUTE_ROW_HEIGHT = 24;

/**
 * Calculate node height based on content.
 * Model nodes: header + column rows.
 * Non-model nodes with attributes: header + attribute area.
 */
function getNodeHeight(node) {
  const data = node.data || {};
  if (data.columns && data.columns.length > 0) {
    return BASE_NODE_HEIGHT + data.columns.length * COLUMN_ROW_HEIGHT;
  }
  if (data.attributes && data.attributes.length > 0) {
    return BASE_NODE_HEIGHT + ATTRIBUTE_ROW_HEIGHT;
  }
  return BASE_NODE_HEIGHT;
}

export function getLayoutedElements(nodes, edges, direction = 'TB') {
  const g = new dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: direction, nodesep: 60, ranksep: 120 });

  nodes.forEach((node) => {
    g.setNode(node.id, { width: NODE_WIDTH, height: getNodeHeight(node) });
  });

  edges.forEach((edge) => {
    g.setEdge(edge.source, edge.target);
  });

  dagre.layout(g);

  const isHorizontal = direction === 'LR';

  const layoutedNodes = nodes.map((node) => {
    const pos = g.node(node.id);
    const height = getNodeHeight(node);
    return {
      ...node,
      targetPosition: isHorizontal ? 'left' : 'top',
      sourcePosition: isHorizontal ? 'right' : 'bottom',
      position: {
        x: pos.x - NODE_WIDTH / 2,
        y: pos.y - height / 2,
      },
    };
  });

  return { nodes: layoutedNodes, edges };
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/lib/layout.js
git commit -m "Support dynamic node heights in dagre layout"
```

---

## Task 8: Refactor App.svelte — state management, sidebar, highlight logic

**Context:** This is the largest frontend change. `App.svelte` becomes the state owner for the three-zone layout. It manages `activeNodeId`, `visibleNodeIds`, `filterText`, `collapsedTypes`, and computes `visibleNodes`/`visibleEdges` with highlight/dim flags. The Flows tab is removed.

**Files:**
- Modify: `frontend/src/App.svelte`
- Delete: `frontend/src/components/FlowView.svelte`

- [ ] **Step 1: Delete FlowView.svelte**

```bash
rm frontend/src/components/FlowView.svelte
```

- [ ] **Step 2: Rewrite App.svelte**

Replace `frontend/src/App.svelte`:

```svelte
<script>
  import GraphView from './components/GraphView.svelte';
  import ClusterView from './components/ClusterView.svelte';
  import NodeDetail from './components/NodeDetail.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import { fetchJSON } from './lib/api.js';

  // ── State ──────────────────────────────────────────────────────────

  let activeTab = $state('graph');
  let activeNodeId = $state(null);
  let visibleNodeIds = $state(new Set());
  let filterText = $state('');
  let collapsedTypes = $state(new Set());

  let allNodes = $state.raw([]);
  let allEdges = $state.raw([]);
  let clusterNodes = $state.raw([]);
  let clusterEdges = $state.raw([]);
  let clusters = $state([]);
  let loading = $state(true);

  // ── Derived ────────────────────────────────────────────────────────

  /** Build adjacency set for the active node (bidirectional). */
  const adjacencySet = $derived.by(() => {
    if (!activeNodeId) return new Set();
    const currentEdges = activeTab === 'graph' ? allEdges : clusterEdges;
    const related = new Set();
    for (const edge of currentEdges) {
      if (edge.source === activeNodeId) related.add(edge.target);
      if (edge.target === activeNodeId) related.add(edge.source);
    }
    return related;
  });

  /** Visible nodes filtered by visibleNodeIds, with highlight flags. */
  const visibleNodes = $derived.by(() => {
    const currentNodes = activeTab === 'graph' ? allNodes : clusterNodes;
    return currentNodes
      .filter((n) => visibleNodeIds.has(n.id))
      .map((n) => ({
        ...n,
        data: {
          ...n.data,
          isActive: activeNodeId ? n.id === activeNodeId : undefined,
          isHighlighted: activeNodeId ? adjacencySet.has(n.id) : undefined,
        },
      }));
  });

  /** Visible edges — only where both endpoints are visible, with highlight. */
  const visibleEdges = $derived.by(() => {
    const currentEdges = activeTab === 'graph' ? allEdges : clusterEdges;
    return currentEdges
      .filter((e) => visibleNodeIds.has(e.source) && visibleNodeIds.has(e.target))
      .map((e) => {
        if (!activeNodeId) return e;
        const isConnected = e.source === activeNodeId || e.target === activeNodeId;
        return {
          ...e,
          style: isConnected
            ? 'stroke: #22c55e; stroke-width: 2px;'
            : `opacity: 0.3; ${e.style || ''}`,
          zIndex: isConnected ? 10 : 0,
        };
      });
  });

  /** The currently selected node object for the detail panel. */
  const selectedNode = $derived(
    activeNodeId
      ? (activeTab === 'graph' ? allNodes : clusterNodes).find((n) => n.id === activeNodeId) || null
      : null
  );

  // ── Data Loading ───────────────────────────────────────────────────

  async function loadGraphData() {
    loading = true;
    try {
      const data = await fetchJSON('graph');
      allNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      allEdges = (data.edges || []).map((e) => ({
        ...e,
        style: e.data?.isCycle ? 'stroke: #ef4444; stroke-width: 2px' : undefined,
        animated: e.data?.isCycle || e.animated || false,
      }));
      visibleNodeIds = new Set(allNodes.map((n) => n.id));
      initCollapsedTypes(allNodes);
    } catch (e) {
      console.error('Failed to load graph:', e);
    }
    loading = false;
  }

  async function loadClusterData() {
    loading = true;
    try {
      const data = await fetchJSON('clusters');
      clusterNodes = (data.nodes || []).map((n) => ({
        ...n,
        type: n.data?.unitType === 'model' ? 'model' : 'compact',
        position: n.position || { x: 0, y: 0 },
      }));
      clusterEdges = (data.edges || []).map((e) => ({
        ...e,
        animated: e.data?.relationship === 'boundary' || e.animated || false,
        style: e.data?.relationship === 'boundary'
          ? 'stroke: #22d3ee; stroke-dasharray: 5 5'
          : undefined,
      }));
      clusters = data.clusters || [];
      // For clusters, show all cluster members
      if (activeTab === 'clusters') {
        visibleNodeIds = new Set(clusterNodes.map((n) => n.id));
        initCollapsedTypes(clusterNodes);
      }
    } catch (e) {
      console.error('Failed to load clusters:', e);
    }
    loading = false;
  }

  function initCollapsedTypes(nodes) {
    const types = [...new Set(nodes.map((n) => n.data?.unitType || 'default'))];
    const sortOrder = ['model', 'controller', 'job', 'service', 'mailer', 'concern'];
    types.sort((a, b) => {
      const ai = sortOrder.indexOf(a);
      const bi = sortOrder.indexOf(b);
      if (ai !== -1 && bi !== -1) return ai - bi;
      if (ai !== -1) return -1;
      if (bi !== -1) return 1;
      return a.localeCompare(b);
    });
    // All collapsed except the first type
    collapsedTypes = new Set(types.slice(1));
  }

  // ── Event Handlers ─────────────────────────────────────────────────

  function switchTab(tab) {
    if (activeTab === tab) return;
    activeTab = tab;
    activeNodeId = null;
    filterText = '';
    if (tab === 'clusters' && clusterNodes.length === 0) {
      loadClusterData();
    } else if (tab === 'clusters') {
      visibleNodeIds = new Set(clusterNodes.map((n) => n.id));
      initCollapsedTypes(clusterNodes);
    } else {
      visibleNodeIds = new Set(allNodes.map((n) => n.id));
      initCollapsedTypes(allNodes);
    }
  }

  function handleNodeSelect(node) {
    activeNodeId = node?.id || null;
  }

  function handleCanvasClick() {
    activeNodeId = null;
  }

  function handleCloseDetail() {
    activeNodeId = null;
  }

  function handleSelectUnit(unitId) {
    activeNodeId = unitId;
  }

  function handleToggleVisibility(unitId) {
    const next = new Set(visibleNodeIds);
    if (next.has(unitId)) {
      next.delete(unitId);
    } else {
      next.add(unitId);
    }
    visibleNodeIds = next;
  }

  function handleFocusUnit(unitId) {
    const currentEdges = activeTab === 'graph' ? allEdges : clusterEdges;
    const related = new Set([unitId]);
    for (const edge of currentEdges) {
      if (edge.source === unitId) related.add(edge.target);
      if (edge.target === unitId) related.add(edge.source);
    }
    visibleNodeIds = related;
    activeNodeId = unitId;
  }

  function handleToggleCollapse(type) {
    const next = new Set(collapsedTypes);
    if (next.has(type)) {
      next.delete(type);
    } else {
      next.add(type);
    }
    collapsedTypes = next;
  }

  function handleShowAll() {
    const currentNodes = activeTab === 'graph' ? allNodes : clusterNodes;
    visibleNodeIds = new Set(currentNodes.map((n) => n.id));
  }

  function handleHideAll() {
    visibleNodeIds = new Set();
  }

  // ── Init ───────────────────────────────────────────────────────────

  loadGraphData();
  loadClusterData();
</script>

<div class="header">
  <h1>Woods <span>Visualize</span></h1>
  <div class="tabs">
    <button
      class="tab"
      class:active={activeTab === 'graph'}
      onclick={() => switchTab('graph')}
    >
      Dependencies
    </button>
    <button
      class="tab"
      class:active={activeTab === 'clusters'}
      onclick={() => switchTab('clusters')}
    >
      Clusters
    </button>
  </div>
</div>

<Sidebar
  allNodes={activeTab === 'graph' ? allNodes : clusterNodes}
  {activeNodeId}
  {visibleNodeIds}
  bind:filterText
  {collapsedTypes}
  onSelectUnit={handleSelectUnit}
  onToggleVisibility={handleToggleVisibility}
  onFocusUnit={handleFocusUnit}
  onToggleCollapse={handleToggleCollapse}
  onShowAll={handleShowAll}
  onHideAll={handleHideAll}
/>

<div class="main-content">
  {#if activeTab === 'graph'}
    <GraphView
      nodes={visibleNodes}
      edges={visibleEdges}
      {loading}
      onNodeSelect={handleNodeSelect}
      onCanvasClick={handleCanvasClick}
    />
  {:else if activeTab === 'clusters'}
    <ClusterView
      nodes={visibleNodes}
      edges={visibleEdges}
      {loading}
      onNodeSelect={handleNodeSelect}
      onCanvasClick={handleCanvasClick}
    />
  {/if}
</div>

<NodeDetail node={selectedNode} onClose={handleCloseDetail} />

<div class="stats-bar">
  <div class="stat">
    Visible: <span class="stat-value">{visibleNodes.length}</span> / {activeTab === 'graph' ? allNodes.length : clusterNodes.length}
  </div>
  {#if clusters.length > 0 && activeTab === 'clusters'}
    <div class="stat">
      Clusters: <span class="stat-value">{clusters.length}</span>
    </div>
  {/if}
</div>

<style>
  .main-content {
    position: relative;
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }
</style>
```

- [ ] **Step 3: Commit**

```bash
git rm frontend/src/components/FlowView.svelte
git add frontend/src/App.svelte
git commit -m "Refactor App.svelte with sidebar state, highlight logic, remove Flows tab"
```

---

## Task 9: Refactor GraphView and ClusterView to accept props

**Context:** GraphView and ClusterView currently fetch their own data and manage their own nodes/edges. They need to be refactored to accept `nodes`, `edges`, `loading`, `onNodeSelect`, and `onCanvasClick` as props from App.svelte. They use ModelNode and CompactNode instead of WoodsNode.

**Files:**
- Modify: `frontend/src/components/GraphView.svelte`
- Modify: `frontend/src/components/ClusterView.svelte`
- Delete: `frontend/src/components/WoodsNode.svelte`

- [ ] **Step 1: Rewrite GraphView.svelte**

Replace `frontend/src/components/GraphView.svelte`:

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { getLayoutedElements } from '../lib/layout.js';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';

  let { nodes = [], edges = [], loading = false, onNodeSelect, onCanvasClick } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  const layouted = $derived.by(() => {
    if (nodes.length === 0) return { nodes: [], edges: [] };
    return getLayoutedElements(nodes, edges, 'TB');
  });

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  $effect(() => {
    layoutedNodes = layouted.nodes;
    layoutedEdges = layouted.edges;
  });

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  function handlePaneClick() {
    onCanvasClick?.();
  }
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading graph...</div>
  {:else if layoutedNodes.length === 0}
    <div class="loading-overlay">No visible nodes. Use the sidebar to show units.</div>
  {:else}
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
      fitView
      minZoom={0.05}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
    </SvelteFlow>
  {/if}
</div>
```

- [ ] **Step 2: Rewrite ClusterView.svelte**

Replace `frontend/src/components/ClusterView.svelte`:

```svelte
<script>
  import {
    SvelteFlow,
    Controls,
    MiniMap,
    Background,
  } from '@xyflow/svelte';
  import { getLayoutedElements } from '../lib/layout.js';
  import ModelNode from './ModelNode.svelte';
  import CompactNode from './CompactNode.svelte';

  let { nodes = [], edges = [], loading = false, onNodeSelect, onCanvasClick } = $props();

  const nodeTypes = { model: ModelNode, compact: CompactNode };

  const layouted = $derived.by(() => {
    if (nodes.length === 0) return { nodes: [], edges: [] };
    return getLayoutedElements(nodes, edges, 'TB');
  });

  let layoutedNodes = $state.raw([]);
  let layoutedEdges = $state.raw([]);

  $effect(() => {
    layoutedNodes = layouted.nodes;
    layoutedEdges = layouted.edges;
  });

  function handleNodeClick({ node }) {
    onNodeSelect?.(node);
  }

  function handlePaneClick() {
    onCanvasClick?.();
  }
</script>

<div class="flow-container">
  {#if loading}
    <div class="loading-overlay">Loading clusters...</div>
  {:else if layoutedNodes.length === 0}
    <div class="loading-overlay">No visible nodes. Use the sidebar to show units.</div>
  {:else}
    <SvelteFlow
      bind:nodes={layoutedNodes}
      bind:edges={layoutedEdges}
      {nodeTypes}
      onnodeclick={handleNodeClick}
      onpaneclick={handlePaneClick}
      fitView
      minZoom={0.05}
      maxZoom={2}
    >
      <Controls />
      <MiniMap />
      <Background />
    </SvelteFlow>
  {/if}
</div>
```

- [ ] **Step 3: Delete WoodsNode.svelte**

```bash
rm frontend/src/components/WoodsNode.svelte
```

- [ ] **Step 4: Commit**

```bash
git rm frontend/src/components/WoodsNode.svelte
git add frontend/src/components/GraphView.svelte frontend/src/components/ClusterView.svelte
git commit -m "Refactor GraphView/ClusterView to accept props, use ModelNode/CompactNode"
```

---

## Task 10: Update NodeDetail with dependency counts and column detail

**Context:** The right detail panel needs dependency/dependent counts and, for model nodes, a column detail section.

**Files:**
- Modify: `frontend/src/components/NodeDetail.svelte`

- [ ] **Step 1: Rewrite NodeDetail.svelte**

Replace `frontend/src/components/NodeDetail.svelte`:

```svelte
<script>
  let { node, onClose } = $props();

  const d = $derived(node?.data || {});
  const rows = $derived.by(() => {
    const r = [
      ['Type', d.unitType || node?.type || '-'],
      ['File', d.filePath || '-'],
    ];
    if (d.namespace) r.push(['Namespace', d.namespace]);
    r.push(['PageRank', d.pagerank ? d.pagerank.toFixed(6) : '-']);
    if (d.isHub) r.push(['Role', 'Hub']);
    if (d.isBridge) r.push(['Role', 'Bridge']);
    if (d.isOrphan) r.push(['Role', 'Orphan']);
    if (d.dependencyCount !== undefined) r.push(['Dependencies', d.dependencyCount]);
    if (d.dependentCount !== undefined) r.push(['Dependents', d.dependentCount]);
    return r;
  });

  const columns = $derived(d.columns || []);
</script>

{#if node}
  <div class="detail-panel open">
    <div class="detail-panel-header">
      <h3>{node.id}</h3>
      <button class="close-btn" onclick={onClose} aria-label="Close detail panel">&times;</button>
    </div>
    <div class="detail-panel-body">
      {#each rows as [label, value]}
        <div class="detail-row">
          <span class="detail-label">{label}</span>
          <span class="detail-value">{value}</span>
        </div>
      {/each}

      {#if columns.length > 0}
        <div style="margin-top:12px;">
          <div class="detail-label" style="margin-bottom:6px; font-size:11px; font-weight:600;">Columns</div>
          {#each columns as col}
            <div class="detail-row">
              <span class="detail-label" style="font-size:11px;">
                {#if col.primary}&#x1F511;{:else if col.foreign}&#x1F517;{:else if !col.nullable}&#x25C6;{:else}&#x25C7;{/if}
                {col.name}
              </span>
              <span class="detail-value" style="font-size:11px;">{col.type}</span>
            </div>
          {/each}
        </div>
      {/if}
    </div>
  </div>
{/if}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/components/NodeDetail.svelte
git commit -m "Enhance NodeDetail with dependency counts and column detail"
```

---

## Task 11: Build frontend and update gem assets

**Context:** After all frontend changes, rebuild the Vite bundle to update the pre-built assets that ship with the gem. This is the final step that makes everything work in the host app.

**Files:**
- Rebuild: `lib/woods/svelte_flow/assets/build/app.js` and `app.css` (auto-generated by Vite)

- [ ] **Step 1: Install dependencies and build**

```bash
cd frontend && npm install && npm run build
```

Expected output should show the build completing with `app.js` and `app.css` output files.

- [ ] **Step 2: Verify build output exists**

```bash
ls -la lib/woods/svelte_flow/assets/build/
```

Expected: `app.js`, `app.css`, and possibly `index.html`

- [ ] **Step 3: Commit built assets**

```bash
cd /path/to/lost-in-the/woods-flow
git add lib/woods/svelte_flow/assets/build/
git commit -m "Rebuild Svelte Flow frontend with navigation redesign"
```

---

## Task 12: Run full test suite and verify

**Context:** Final verification. Run all svelte_flow specs to ensure nothing is broken, then run rubocop.

**Files:** None (verification only)

- [ ] **Step 1: Run svelte_flow specs**

```bash
bundle exec rspec spec/svelte_flow/ --format progress --format json --out tmp/test_results.json
```

Expected: ALL PASS

- [ ] **Step 2: Run rubocop on changed files**

```bash
bundle exec rubocop lib/woods/svelte_flow/ --format simple
```

Expected: No offenses (or only pre-existing ones in `.rubocop_todo.yml`)

- [ ] **Step 3: Run full gem spec suite**

```bash
bundle exec rake spec --format progress --format json --out tmp/test_results.json
```

Expected: ALL PASS

- [ ] **Step 4: Commit any rubocop fixes if needed**

```bash
git add -A && git commit -m "Fix rubocop offenses in svelte_flow module"
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Requirement | Task |
|---|---|
| Left sidebar with filter, type groups, visibility toggles | Task 6 (Sidebar, TypeGroup), Task 8 (App.svelte state) |
| Center canvas with ModelNode and CompactNode | Task 5 (components), Task 9 (GraphView/ClusterView) |
| Right detail panel with dependency counts and columns | Task 10 (NodeDetail) |
| Highlight/dim behavior on node selection | Task 8 (App.svelte adjacency + derived state) |
| Model nodes show columns with borders | Task 5 (ModelNode.svelte) |
| CompactNode shows type-specific attributes | Task 5 (CompactNode.svelte) |
| ALT+Click focus mode | Task 6 (TypeGroup onclick), Task 8 (handleFocusUnit) |
| Show All / Hide All | Task 6 (Sidebar), Task 8 (handlers) |
| Flows tab removed | Task 8 (App.svelte) |
| Symbol-or-string cleanup | Task 2 (Transformer) |
| NodeBuilder enrichment (columns, attributes, counts) | Task 1 |
| Transformer passes unit metadata | Task 2 |
| Exporter loads unit metadata | Task 3 |
| Dynamic node heights in layout | Task 7 |
| Updated type colors | Task 4 |
| WCAG AA accessibility (focus indicators, non-color signals) | Task 4 (CSS), Task 5 (border width changes), Task 6 (ARIA attributes, keyboard handlers) |
| Frontend build | Task 11 |

### Placeholder Scan

No TBD, TODO, or "implement later" found. All code blocks are complete.

### Type Consistency

- `unit_metadata` parameter name used consistently in NodeBuilder, Transformer, Exporter
- `forward_edges` / `reverse_edges` parameter names consistent across NodeBuilder and Transformer
- `isActive` / `isHighlighted` flags used in App.svelte derived state match what ModelNode/CompactNode check
- `onNodeSelect` / `onCanvasClick` prop names consistent between App.svelte and GraphView/ClusterView
- `visibleNodeIds` is `Set<string>` everywhere
- `collapsedTypes` is `Set<string>` everywhere
- Node `type` is `'model'` or `'compact'` — matches `nodeTypes` in GraphView/ClusterView
