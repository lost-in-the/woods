# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Converts dependency graph nodes into Svelte Flow node objects.
    #
    # Maps unit types to custom Svelte Flow node types and enriches node data
    # with PageRank scores, structural roles (hub, bridge, orphan), and metadata.
    #
    # @example
    #   builder = NodeBuilder.new(
    #     nodes: { "User" => { type: :model, file_path: "app/models/user.rb", namespace: nil } },
    #     positions: { "User" => { "x" => 0, "y" => 0 } },
    #     pagerank: { "User" => 0.05 },
    #     analysis: { hubs: [...], bridges: [...], orphans: [...] }
    #   )
    #   builder.build  # => [{ "id" => "User", "type" => "model", "position" => ..., "data" => ... }]
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
      def initialize(nodes:, positions:, pagerank: {}, analysis: {})
        @nodes = nodes
        @positions = positions
        @pagerank = pagerank
        @hub_ids = extract_identifiers(analysis[:hubs] || analysis['hubs'])
        @bridge_ids = extract_identifiers(analysis[:bridges] || analysis['bridges'])
        @orphan_ids = Set.new(analysis[:orphans] || analysis['orphans'] || [])
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

        {
          'id' => identifier,
          'type' => UNIT_TYPE_MAP.fetch(unit_type, 'default'),
          'position' => position,
          'data' => {
            'label' => identifier,
            'unitType' => unit_type.to_s,
            'filePath' => meta[:file_path] || meta['file_path'],
            'namespace' => meta[:namespace] || meta['namespace'],
            'pagerank' => @pagerank[identifier] || 0,
            'isHub' => @hub_ids.include?(identifier),
            'isBridge' => @bridge_ids.include?(identifier),
            'isOrphan' => @orphan_ids.include?(identifier)
          }
        }
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
