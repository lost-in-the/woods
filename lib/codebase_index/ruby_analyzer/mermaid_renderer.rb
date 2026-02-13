# frozen_string_literal: true

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

        seen_nodes = {}
        edges = []

        units.each do |unit|
          node_id = sanitize_id(unit.identifier)
          unless seen_nodes[node_id]
            seen_nodes[node_id] = true
            lines << "  #{node_id}[\"#{escape_label(unit.identifier)}\"]"
          end

          (unit.dependencies || []).each do |dep|
            target = dep[:target] || dep['target']
            next unless target

            target_id = sanitize_id(target)
            unless seen_nodes[target_id]
              seen_nodes[target_id] = true
              lines << "  #{target_id}[\"#{escape_label(target)}\"]"
            end

            via = dep[:via] || dep['via']
            edge_key = "#{node_id}->#{target_id}"
            next if edges.include?(edge_key)

            edges << edge_key
            if via
              lines << "  #{node_id} -->|#{via}| #{target_id}"
            else
              lines << "  #{node_id} --> #{target_id}"
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
        seen_edges = []
        edges.each do |source, targets|
          targets = Array(targets)
          targets.each do |target|
            next unless nodes.key?(target)

            edge_key = "#{sanitize_id(source)}->#{sanitize_id(target)}"
            next if seen_edges.include?(edge_key)

            seen_edges << edge_key
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

        seen_nodes = {}

        units.each do |unit|
          transformations = unit.metadata[:data_transformations] || unit.metadata['data_transformations']
          next unless transformations.is_a?(Array) && transformations.any?

          node_id = sanitize_id(unit.identifier)
          unless seen_nodes[node_id]
            seen_nodes[node_id] = true
            shape = dataflow_shape(transformations)
            lines << "  #{node_id}#{shape}"
          end

          transformations.each do |t|
            receiver = t[:receiver] || t['receiver']
            next unless receiver

            receiver_id = sanitize_id(receiver)
            category = (t[:category] || t['category'])&.to_s
            method_name = t[:method] || t['method']

            unless seen_nodes[receiver_id]
              seen_nodes[receiver_id] = true
              lines << "  #{receiver_id}[\"#{escape_label(receiver)}\"]"
            end

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
        if analysis
          stats = analysis[:stats] || analysis['stats'] || {}
          sections << "- **Orphans:** #{stats[:orphan_count] || stats['orphan_count'] || 0}"
          sections << "- **Dead ends:** #{stats[:dead_end_count] || stats['dead_end_count'] || 0}"
          sections << "- **Hubs:** #{stats[:hub_count] || stats['hub_count'] || 0}"
          sections << "- **Cycles:** #{stats[:cycle_count] || stats['cycle_count'] || 0}"

          hubs = analysis[:hubs] || analysis['hubs'] || []
          if hubs.any?
            sections << ''
            sections << '### Top Hubs'
            sections << ''
            hubs.first(5).each do |hub|
              id = hub[:identifier] || hub['identifier']
              count = hub[:dependent_count] || hub['dependent_count']
              sections << "- #{id} (#{count} dependents)"
            end
          end

          cycles = analysis[:cycles] || analysis['cycles'] || []
          if cycles.any?
            sections << ''
            sections << '### Cycles'
            sections << ''
            cycles.each do |cycle|
              sections << "- #{cycle.join(' -> ')}"
            end
          end
        end

        sections.join("\n")
      end

      private

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
        label.to_s.gsub('"', '#quot;')
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
          "[/\"serialization\"/]"
        elsif categories.include?(:deserialization)
          "[\\\"deserialization\"\\]"
        else
          "[\"data\"]"
        end
      end
    end
  end
end
