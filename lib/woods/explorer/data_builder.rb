# frozen_string_literal: true

require 'woods/explorer/errors'
require 'woods/explorer/type_groups'
require 'woods/explorer/unit_summarizer'
require 'woods/explorer/screen_builder'

module Woods
  module Explorer
    # Normalizes an extraction index into the single JSON payload the explorer
    # frontend consumes (and the `data.json` sidecar AI agents read). The
    # payload is deterministic for a given extraction — nodes are sorted by
    # identifier, edges by (source, target, via) — so re-exports of an
    # unchanged index are byte-identical.
    #
    # Reads the dependency graph via IndexReader#raw_graph_data (string keys +
    # persisted pagerank — never #dependency_graph, which drops pagerank), and
    # per-unit JSON only for node detail bodies.
    class DataBuilder
      # Payload schema identifier. Bump when the shape changes incompatibly.
      # v2 adds screens, flow summaries + inverted indexes, and flow_ops.
      SCHEMA = 'woods-explorer/2'

      # Unit types excluded unless include_framework is set. gem_source units
      # are unreachable via IndexReader::TYPE_DIRS but can still appear as
      # graph nodes, so both are filtered here.
      FRAMEWORK_TYPES = %w[rails_source gem_source].freeze

      # @return [Hash] counters accumulated during the last #build
      attr_reader :stats

      # @param reader [Woods::MCP::IndexReader]
      # @param include_framework [Boolean] include rails_source/gem_source nodes
      # @param flow_digest [Hash, nil] FlowDigest#build output (injected by
      #   SiteBuilder; nil degrades to a flow-less payload)
      # @param labels [Hash] parsed woods_labels.yml
      def initialize(reader:, include_framework: false, flow_digest: nil, labels: {})
        @reader = reader
        @include_framework = include_framework
        @flow_digest = flow_digest || { 'summaries' => [], 'ops' => [],
                                        'unit_index' => {}, 'method_index' => {} }
        @labels = labels
        @stats = { skipped_units: 0, skipped_edges: 0 }
      end

      # @return [Hash] the versioned explorer payload (string keys)
      def build
        graph = read_graph
        raise ExportError, 'dependency graph has no nodes — run extraction first' if graph_nodes(graph).empty?

        ids = included_ids(graph)
        index_of = ids.each_with_index.to_h
        nodes = build_nodes(graph, ids)
        edges = build_edges(graph, index_of)
        finalize_degrees(nodes, edges)
        payload(graph, nodes, edges, index_of)
      end

      private

      # The graph is the one artifact the explorer can't do without — turn a
      # missing or corrupt dependency_graph.json into the same friendly
      # ExportError the missing-manifest path produces.
      def read_graph
        @reader.raw_graph_data
      rescue SystemCallError, JSON::ParserError => e
        raise ExportError,
              "could not read dependency_graph.json (#{e.class}) — run `bundle exec rake woods:extract` first"
      end

      def graph_nodes(graph)
        graph['nodes'].is_a?(Hash) ? graph['nodes'] : {}
      end

      def included_ids(graph)
        graph_nodes(graph).filter_map do |id, node|
          type = node.is_a?(Hash) ? node['type'].to_s : ''
          next if !@include_framework && FRAMEWORK_TYPES.include?(type)

          id
        end.sort
      end

      def build_nodes(graph, ids)
        pagerank = graph['pagerank'].is_a?(Hash) ? graph['pagerank'] : {}
        ids.map do |id|
          info = graph_nodes(graph)[id] || {}
          unit = load_unit(id)
          node_entry(id, info, unit, pagerank[id])
        end
      end

      def node_entry(id, info, unit, pagerank)
        type = (info['type'] || unit&.fetch('type', nil)).to_s
        summarizer = UnitSummarizer.new(unit)
        {
          'id' => id,
          'type' => type,
          'group' => TypeGroups.group_for(type),
          'label' => short_label(id),
          'namespace' => info['namespace'] || unit&.fetch('namespace', nil),
          'file_path' => unit&.fetch('file_path', nil) || info['file_path'],
          'pagerank' => (pagerank || 0).to_f.round(6),
          'in' => 0, 'out' => 0,
          'summary' => unit ? summarizer.summary_line : type,
          'facts' => unit ? summarizer.facts : {},
          'no_unit' => unit ? nil : true
        }.compact
      end

      def load_unit(identifier)
        unit = @reader.find_unit(identifier)
        @stats[:skipped_units] += 1 if unit.nil?
        unit
      rescue StandardError
        @stats[:skipped_units] += 1
        nil
      end

      def build_edges(graph, index_of)
        raw = graph['edges'].is_a?(Hash) ? graph['edges'] : {}
        edges = raw.flat_map do |source, targets|
          next [] unless targets.is_a?(Array)

          unless index_of.key?(source)
            @stats[:skipped_edges] += targets.size
            next []
          end

          targets.filter_map { |edge| edge_triple(source, edge, index_of) }
        end
        edges.uniq.sort
      end

      # Normalizes hash edges ({'target' =>, 'via' =>}) and legacy bare-string
      # edges into a compact [source_idx, target_idx, via] triple.
      def edge_triple(source, edge, index_of)
        target, via = edge.is_a?(Hash) ? [edge['target'], edge['via']] : [edge, nil]
        unless index_of.key?(target)
          @stats[:skipped_edges] += 1
          return nil
        end
        [index_of[source], index_of[target], via.to_s]
      end

      def finalize_degrees(nodes, edges)
        edges.each do |(src, tgt, _via)|
          nodes[src]['out'] += 1
          nodes[tgt]['in'] += 1
        end
      end

      def payload(graph, nodes, edges, index_of)
        {
          'schema' => SCHEMA,
          'app' => app_info,
          'groups' => group_defs,
          'types' => type_counts(nodes),
          'via_counts' => via_counts(edges),
          'nodes' => nodes,
          'edges' => edges,
          'screens' => build_screens(nodes, edges),
          'flows' => {
            'available' => !@flow_digest['summaries'].empty?,
            'summaries' => @flow_digest['summaries'],
            'unit_index' => @flow_digest['unit_index'],
            'method_index' => @flow_digest['method_index']
          },
          'flow_ops' => @flow_digest['ops'],
          'analysis' => remap_analysis(index_of),
          'meta' => { 'include_framework' => @include_framework,
                      'skipped_units' => @stats[:skipped_units],
                      'skipped_edges' => @stats[:skipped_edges],
                      'graph_stats' => graph['stats'].is_a?(Hash) ? graph['stats'] : {} }
        }
      end

      def build_screens(nodes, edges)
        ScreenBuilder.new(nodes: nodes, edges: edges,
                          flow_digest: @flow_digest, labels: @labels).build
      end

      def app_info
        # Provenance is decorative — a corrupt manifest.json shouldn't sink
        # the export when every other artifact is healthy.
        manifest = begin
          @reader.manifest || {}
        rescue StandardError
          {}
        end
        {
          'extracted_at' => manifest['extracted_at'],
          'rails_version' => manifest['rails_version'],
          'ruby_version' => manifest['ruby_version'],
          'git_branch' => manifest['git_branch'],
          'git_sha' => manifest['git_sha'],
          'total_units' => manifest['total_units']
        }.compact
      end

      def group_defs
        TypeGroups.all.map do |family|
          { 'key' => family[:key], 'label' => family[:label],
            'glyph' => family[:glyph], 'types' => family[:types] }
        end
      end

      def type_counts(nodes)
        nodes.each_with_object(Hash.new(0)) { |node, counts| counts[node['type']] += 1 }
             .sort_by { |type, count| [-count, type] }.to_h
      end

      def via_counts(edges)
        edges.each_with_object(Hash.new(0)) { |(_s, _t, via), counts| counts[via] += 1 }
             .sort_by { |via, count| [-count, via] }.to_h
      end

      # Rewrites graph_analysis.json identifier lists into node indices so the
      # frontend never has to join by string id. Identifiers outside the
      # included node set (e.g. framework nodes when include_framework is off)
      # are dropped.
      def remap_analysis(index_of)
        analysis = safe_analysis
        return {} unless analysis.is_a?(Hash)

        {
          'orphans' => remap_ids(analysis['orphans'], index_of),
          'dead_ends' => remap_ids(analysis['dead_ends'], index_of),
          'hubs' => remap_hubs(analysis['hubs'], index_of),
          'cycles' => remap_cycles(analysis['cycles'], index_of),
          'bridges' => remap_bridges(analysis['bridges'], index_of),
          'stats' => analysis['stats'].is_a?(Hash) ? analysis['stats'] : {}
        }
      end

      def safe_analysis
        @reader.graph_analysis
      rescue StandardError
        nil
      end

      def remap_ids(ids, index_of)
        Array(ids).filter_map { |id| index_of[id] }
      end

      def remap_hubs(hubs, index_of)
        Array(hubs).filter_map do |hub|
          next unless hub.is_a?(Hash) && index_of.key?(hub['identifier'])

          { 'node' => index_of[hub['identifier']],
            'dependent_count' => hub['dependent_count'] }.compact
        end
      end

      def remap_cycles(cycles, index_of)
        Array(cycles).filter_map do |cycle|
          mapped = Array(cycle).map { |id| index_of[id] }
          mapped.all? ? mapped : nil
        end
      end

      def remap_bridges(bridges, index_of)
        Array(bridges).filter_map do |bridge|
          next unless bridge.is_a?(Hash) && index_of.key?(bridge['identifier'])

          { 'node' => index_of[bridge['identifier']], 'score' => bridge['score'] }.compact
        end
      end

      def short_label(id)
        id.split('::').last.to_s
      end
    end
  end
end
