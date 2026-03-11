# frozen_string_literal: true

require 'set'

module CodebaseIndex
  module RubyAnalyzer
    # Renders Mermaid-format diagrams from extracted units, dependency graphs,
    # and graph analysis data.
    #
    # Produces valid Mermaid markdown strings for call graphs, dependency maps,
    # dataflow charts, and combined architecture documents.
    #
    # @example Rendering a call graph
    #   renderer = MermaidRenderer.new
    #   units = RubyAnalyzer.analyze(paths: ["lib/"])
    #   puts renderer.render_call_graph(units)
    #
    class MermaidRenderer
      # Render a call graph from extracted units showing method call relationships.
      #
      # Each unit with dependencies produces edges to its targets. Nodes are
      # styled by type (class, module, method).
      #
      # @param units [Array<ExtractedUnit>] Units to render
      # @return [String] Mermaid graph TD markdown
      def render_call_graph(units)
        lines = ['graph TD']
        return lines.join("\n") if units.nil? || units.empty?

        seen_nodes = Set.new
        seen_edges = Set.new

        units.each do |unit|
          node_id = sanitize_id(unit.identifier)
          lines << "  #{node_id}[\"#{escape_label(unit.identifier)}\"]" if seen_nodes.add?(node_id)

          (unit.dependencies || []).each do |dep|
            target = dep[:target] || dep['target']
            next unless target

            target_id = sanitize_id(target)
            lines << "  #{target_id}[\"#{escape_label(target)}\"]" if seen_nodes.add?(target_id)

            via = dep[:via] || dep['via']
            edge_key = "#{node_id}->#{target_id}"
            next unless seen_edges.add?(edge_key)

            lines << if via
                       "  #{node_id} -->|#{via}| #{target_id}"
                     else
                       "  #{node_id} --> #{target_id}"
                     end
          end
        end

        lines.join("\n")
      end

      # Render a dependency map from graph data (as returned by DependencyGraph#to_h).
      #
      # Shows nodes grouped by type with edges representing dependencies.
      #
      # @param graph_data [Hash] Serialized graph data with :nodes and :edges keys
      # @return [String] Mermaid graph TD markdown
      def render_dependency_map(graph_data)
        lines = ['graph TD']
        return lines.join("\n") unless graph_data

        nodes = graph_data[:nodes] || graph_data['nodes'] || {}
        edges = graph_data[:edges] || graph_data['edges'] || {}

        return lines.join("\n") if nodes.empty?

        # Group nodes by type for subgraph rendering
        by_type = {}
        nodes.each do |identifier, meta|
          type = (meta[:type] || meta['type'])&.to_sym || :unknown
          by_type[type] ||= []
          by_type[type] << identifier
        end

        # Render subgraphs per type
        by_type.each do |type, identifiers|
          lines << "  subgraph #{type}"
          identifiers.each do |id|
            node_id = sanitize_id(id)
            lines << "    #{node_id}[\"#{escape_label(id)}\"]"
          end
          lines << '  end'
        end

        # Render edges
        seen_edges = Set.new
        edges.each do |source, targets|
          Array(targets).each do |target|
            next unless nodes.key?(target)

            edge_key = "#{sanitize_id(source)}->#{sanitize_id(target)}"
            next unless seen_edges.add?(edge_key)

            lines << "  #{sanitize_id(source)} --> #{sanitize_id(target)}"
          end
        end

        lines.join("\n")
      end

      # Render a dataflow diagram from units that have data_transformations metadata.
      #
      # Shows transformation chains: which units construct, serialize, or
      # deserialize data, with edges flowing between them.
      #
      # @param units [Array<ExtractedUnit>] Units with :data_transformations metadata
      # @return [String] Mermaid flowchart TD markdown
      def render_dataflow(units)
        lines = ['flowchart TD']
        return lines.join("\n") if units.nil? || units.empty?

        seen_nodes = Set.new

        units.each do |unit|
          transformations = unit.metadata[:data_transformations] || unit.metadata['data_transformations']
          next unless transformations.is_a?(Array) && transformations.any?

          node_id = sanitize_id(unit.identifier)
          if seen_nodes.add?(node_id)
            shape = dataflow_shape(transformations)
            lines << "  #{node_id}#{shape}"
          end

          transformations.each do |t|
            receiver = t[:receiver] || t['receiver']
            next unless receiver

            receiver_id = sanitize_id(receiver)
            category = (t[:category] || t['category'])&.to_s
            method_name = t[:method] || t['method']

            lines << "  #{receiver_id}[\"#{escape_label(receiver)}\"]" if seen_nodes.add?(receiver_id)

            label = [category, method_name].compact.join(': ')
            lines << "  #{node_id} -->|#{label}| #{receiver_id}"
          end
        end

        lines.join("\n")
      end

      # Render a combined architecture document with all three diagram types.
      #
      # Returns a markdown document with headers and fenced Mermaid code blocks
      # for call graph, dependency map, and dataflow diagrams, plus a summary
      # of graph analysis findings.
      #
      # @param units [Array<ExtractedUnit>] Extracted units
      # @param graph_data [Hash] Serialized dependency graph data
      # @param analysis [Hash] Graph analysis report from GraphAnalyzer#analyze
      # @return [String] Combined markdown document
      def render_architecture(units, graph_data, analysis)
        sections = []

        sections << '# Architecture Overview'
        sections << ''

        # Call graph
        sections << '## Call Graph'
        sections << ''
        sections << '```mermaid'
        sections << render_call_graph(units)
        sections << '```'
        sections << ''

        # Dependency map
        sections << '## Dependency Map'
        sections << ''
        sections << '```mermaid'
        sections << render_dependency_map(graph_data)
        sections << '```'
        sections << ''

        # Dataflow
        sections << '## Data Flow'
        sections << ''
        sections << '```mermaid'
        sections << render_dataflow(units)
        sections << '```'
        sections << ''

        # Analysis summary
        sections << '## Analysis Summary'
        sections << ''
        sections.concat(render_stats_section(analysis))

        sections.join("\n")
      end

      private

      # Render the Analysis Summary section lines for a given analysis hash.
      #
      # @param analysis [Hash, nil] Graph analysis report from GraphAnalyzer#analyze
      # @return [Array<String>] Lines to append to the architecture document
      def render_stats_section(analysis)
        lines = []
        return lines unless analysis

        stats = analysis[:stats] || analysis['stats'] || {}
        lines << "- **Orphans:** #{stats[:orphan_count] || stats['orphan_count'] || 0}"
        lines << "- **Dead ends:** #{stats[:dead_end_count] || stats['dead_end_count'] || 0}"
        lines << "- **Hubs:** #{stats[:hub_count] || stats['hub_count'] || 0}"
        lines << "- **Cycles:** #{stats[:cycle_count] || stats['cycle_count'] || 0}"

        hubs = analysis[:hubs] || analysis['hubs'] || []
        lines.concat(render_hubs_section(hubs))

        cycles = analysis[:cycles] || analysis['cycles'] || []
        if cycles.any?
          lines << ''
          lines << '### Cycles'
          lines << ''
          cycles.each { |cycle| lines << "- #{cycle.join(' -> ')}" }
        end

        lines
      end

      # Render the Top Hubs subsection lines.
      #
      # @param hubs [Array<Hash>] Hub entries with :identifier and :dependent_count keys
      # @return [Array<String>] Lines to append, or empty array if no hubs
      def render_hubs_section(hubs)
        return [] unless hubs.any?

        lines = ['', '### Top Hubs', '']
        hubs.first(5).each do |hub|
          id = hub[:identifier] || hub['identifier']
          count = hub[:dependent_count] || hub['dependent_count']
          lines << "- #{id} (#{count} dependents)"
        end
        lines
      end

      # Sanitize an identifier for use as a Mermaid node ID.
      #
      # Replaces characters that Mermaid cannot use in node IDs with underscores.
      #
      # @param identifier [String] Raw identifier
      # @return [String] Safe Mermaid node ID
      def sanitize_id(identifier)
        identifier.to_s.gsub(/[^a-zA-Z0-9_]/, '_')
      end

      # Escape a label string for use inside Mermaid quoted labels.
      #
      # @param label [String] Raw label text
      # @return [String] Escaped label
      def escape_label(label)
        label.to_s.gsub('"', '&quot;')
      end

      # Determine Mermaid node shape based on dominant transformation category.
      #
      # @param transformations [Array<Hash>] Transformation metadata
      # @return [String] Mermaid shape syntax
      def dataflow_shape(transformations)
        categories = transformations.map { |t| (t[:category] || t['category'])&.to_sym }

        if categories.include?(:construction)
          "([\"#{escape_label(transformations.first[:method] || 'new')}\"])"
        elsif categories.include?(:serialization)
          '[/"serialization"/]'
        elsif categories.include?(:deserialization)
          '[\"deserialization"\\]'
        else
          '["data"]'
        end
      end
    end
  end
end
