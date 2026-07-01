# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Converts dependency graph nodes into Svelte Flow node objects.
    #
    # Maps unit types to custom Svelte Flow node types and enriches node data
    # with PageRank scores, structural roles (hub, bridge, orphan), column
    # definitions (for models), type-specific attributes, and dependency counts.
    #
    # @example
    #   builder = NodeBuilder.new(
    #     nodes: { "User" => { type: :model, file_path: "app/models/user.rb", namespace: nil } },
    #     positions: { "User" => { "x" => 0, "y" => 0 } },
    #     pagerank: { "User" => 0.05 },
    #     analysis: { hubs: [...], bridges: [...], orphans: [...] },
    #     unit_metadata: { "User" => { "type" => "model", "metadata" => { ... } } },
    #     forward_edges: { "User" => ["Post", "Comment"] },
    #     reverse_edges: { "User" => Set.new(["UsersController"]) }
    #   )
    #   builder.build  # => [{ "id" => "User", "type" => "model", "position" => ..., "data" => ... }]
    #
    class NodeBuilder # rubocop:disable Metrics/ClassLength
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

      # PostgreSQL verbose type aliases. MySQL types are already compact
      # and pass through unchanged after size-stripping.
      COLUMN_TYPE_ALIASES = {
        'character varying' => 'varchar',
        'double precision' => 'float8',
        'timestamp without time zone' => 'timestamp',
        'timestamp with time zone' => 'timestamptz'
      }.freeze

      # @param nodes [Hash<String, Hash>] Graph nodes: identifier => { type:, file_path:, namespace: }
      # @param positions [Hash<String, Hash>] Node positions: identifier => { "x" => n, "y" => n }
      # @param pagerank [Hash<String, Float>] PageRank scores
      # @param analysis [Hash] GraphAnalyzer results with :hubs, :bridges, :orphans keys
      # @param unit_metadata [Hash<String, Hash>] Raw unit metadata keyed by identifier
      # @param forward_edges [Hash<String, Array<String>>] Outgoing dependency edges per identifier
      # @param reverse_edges [Hash<String, Set<String>>] Incoming dependent edges per identifier
      def initialize(nodes:, positions:, pagerank: {}, analysis: {}, # rubocop:disable Metrics/ParameterLists
                     unit_metadata: {}, forward_edges: {}, reverse_edges: {})
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
      def build_node(identifier, meta) # rubocop:disable Metrics
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
          'dependentCount' => @reverse_edges[identifier]&.size || 0
        }

        enrich_node_data(data, identifier, unit_type)

        {
          'id' => identifier,
          'type' => UNIT_TYPE_MAP.fetch(unit_type, 'default'),
          'position' => position,
          'data' => data
        }
      end

      # Enrich node data with type-specific columns or attributes.
      #
      # @param data [Hash] Mutable data hash to enrich in place
      # @param identifier [String] Unit identifier
      # @param unit_type [Symbol] Resolved unit type symbol
      # @return [void]
      def enrich_node_data(data, identifier, unit_type)
        raw = @unit_metadata[identifier]
        return unless raw

        metadata = raw['metadata'] || raw[:metadata] || {}

        if unit_type == :model
          data['columns'] = build_columns(metadata)
        else
          attrs = build_attributes(unit_type, metadata, data['filePath'])
          data['attributes'] = attrs if attrs
        end
      end

      # Build a columns array from model metadata.
      #
      # Each column hash includes: name, type (normalized), primary, foreign, nullable.
      #
      # @param metadata [Hash] Model metadata containing 'columns', 'primary_key', 'associations'
      # @return [Array<Hash>]
      def build_columns(metadata) # rubocop:disable Metrics
        columns = metadata['columns'] || metadata[:columns] || []
        primary_key = metadata['primary_key'] || metadata[:primary_key]
        fk_set = extract_foreign_keys(metadata)

        columns.map do |col|
          name = col['name'] || col[:name]
          raw_type = col['type'] || col[:type] || ''
          # Use key? so that an explicit false value is not lost through || short-circuit
          null_val = col.key?('null') ? col['null'] : col[:null]

          {
            'name' => name,
            'type' => normalize_column_type(raw_type),
            'primary' => name == primary_key,
            'foreign' => fk_set.include?(name),
            'nullable' => null_val != false
          }
        end
      end

      # Extract foreign key column names from associations metadata.
      #
      # @param metadata [Hash] Model metadata with 'associations' key
      # @return [Set<String>]
      def extract_foreign_keys(metadata)
        associations = metadata['associations'] || metadata[:associations] || []
        fk_set = Set.new
        associations.each do |assoc|
          fk = assoc['foreign_key'] || assoc[:foreign_key]
          fk_set << fk.to_s if fk
        end
        fk_set
      end

      # Normalize a SQL column type string by stripping sizes and aliasing verbose types.
      #
      # @param raw [String] Raw SQL type (e.g. "character varying(255)", "bigint")
      # @return [String] Normalized type
      def normalize_column_type(raw)
        # Strip parenthesized sizes/precision first, then check aliases
        stripped = raw.gsub(/\(\d+(?:,\s*\d+)?\)/, '').strip
        COLUMN_TYPE_ALIASES.fetch(stripped, stripped)
      end

      # Build an attributes array appropriate for the given unit type.
      #
      # @param unit_type [Symbol]
      # @param metadata [Hash]
      # @param file_path [String, nil]
      # @return [Array<String>]
      def build_attributes(unit_type, metadata, file_path) # rubocop:disable Metrics
        case unit_type
        when :controller, :mailer
          actions = metadata['actions'] || metadata[:actions]
          actions&.map(&:to_s) || file_path_attribute(file_path)
        when :job
          queue = metadata['queue'] || metadata[:queue]
          queue ? ["queue: #{queue}"] : file_path_attribute(file_path)
        when :concern
          included_by = metadata['included_by'] || metadata[:included_by]
          included_by&.map(&:to_s) || []
        when :route
          verb = metadata['verb'] || metadata[:verb]
          path = metadata['path'] || metadata[:path]
          verb && path ? ["#{verb} #{path}"] : file_path_attribute(file_path)
        when :middleware, :engine
          mount_path = metadata['mount_path'] || metadata[:mount_path]
          mount_path ? [mount_path.to_s] : file_path_attribute(file_path)
        else
          file_path_attribute(file_path)
        end
      end

      # Return a single-element array with the path starting from app/.
      #
      # @param file_path [String, nil]
      # @return [Array<String>]
      def file_path_attribute(file_path)
        return [] unless file_path

        # Strip everything before app/ so callers get a relative app-root path
        trimmed = file_path.sub(%r{\A.*?(app/)}, '\1')
        [trimmed]
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
