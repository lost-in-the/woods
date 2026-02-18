# frozen_string_literal: true

require 'json'
require 'pathname'
require 'set'

module CodebaseIndex
  module MCP
    # Reads extraction output from disk for the MCP server.
    #
    # Lazy-loads unit JSON files on demand with an LRU-ish cache cap.
    # Builds an identifier index from _index.json files for fast lookups.
    #
    # @example
    #   reader = IndexReader.new("/path/to/codebase_index")
    #   reader.find_unit("Post")      # => Hash (full unit data)
    #   reader.list_units(type: "model") # => Array<Hash>
    #
    class IndexReader
      # Directories that correspond to extractor types in the output.
      TYPE_DIRS = %w[
        models controllers services components view_components
        jobs mailers graphql serializers rails_source
      ].freeze

      # Singular type name for each directory (used in search filtering).
      DIR_TO_TYPE = {
        'models' => 'model',
        'controllers' => 'controller',
        'services' => 'service',
        'components' => 'component',
        'view_components' => 'view_component',
        'jobs' => 'job',
        'mailers' => 'mailer',
        'graphql' => 'graphql',
        'serializers' => 'serializer',
        'rails_source' => 'rails_source'
      }.freeze

      TYPE_TO_DIR = DIR_TO_TYPE.invert.freeze

      # Maximum number of loaded unit files to cache in memory.
      MAX_UNIT_CACHE = 50

      # @param index_dir [String] Path to extraction output directory
      # @raise [ArgumentError] if directory doesn't exist or has no manifest.json
      def initialize(index_dir)
        @index_dir = Pathname.new(index_dir)
        raise ArgumentError, "Index directory does not exist: #{index_dir}" unless @index_dir.directory?
        raise ArgumentError, "No manifest.json found in: #{index_dir}" unless @index_dir.join('manifest.json').file?

        @unit_cache = {}
        @unit_cache_order = []
        @identifier_map = nil
      end

      # Clear all cached state so the next access re-reads from disk.
      #
      # @return [void]
      def reload!
        @unit_cache = {}
        @unit_cache_order = []
        @identifier_map = nil
        @index_cache = {}
        @manifest = nil
        @summary = nil
        @dependency_graph = nil
        @graph_analysis = nil
        @raw_graph_data = nil
      end

      # @return [Hash] Parsed manifest.json
      def manifest
        @manifest ||= parse_json('manifest.json')
      end

      # @return [String, nil] SUMMARY.md content, or nil if not present
      def summary
        @summary ||= begin
          path = @index_dir.join('SUMMARY.md')
          path.file? ? path.read : nil
        end
      end

      # @return [CodebaseIndex::DependencyGraph] Graph loaded from disk
      def dependency_graph
        @dependency_graph ||= begin
          data = parse_json('dependency_graph.json')
          CodebaseIndex::DependencyGraph.from_h(data)
        end
      end

      # @return [Hash] Parsed graph_analysis.json
      def graph_analysis
        @graph_analysis ||= parse_json('graph_analysis.json')
      end

      # Find a single unit by identifier.
      #
      # @param identifier [String] Unit identifier (e.g. "Post", "Api::V1::HealthController")
      # @return [Hash, nil] Full unit data or nil if not found
      def find_unit(identifier)
        location = identifier_map[identifier]
        return nil unless location

        load_unit(location[:type_dir], location[:filename])
      end

      # List units, optionally filtered by type.
      #
      # @param type [String, nil] Singular type name (e.g. "model", "controller")
      # @return [Array<Hash>] Index entries for matching units
      def list_units(type: nil)
        dirs = if type
                 dir = TYPE_TO_DIR[type]
                 dir ? [dir] : []
               else
                 TYPE_DIRS
               end

        dirs.flat_map { |dir| read_index(dir) }
      end

      # Search units by case-insensitive pattern.
      #
      # Phase 1: match identifiers from index files (cheap).
      # Phase 2: lazy-load unit files for metadata/source_code matching.
      #
      # @param query [String] Search pattern (treated as case-insensitive regex)
      # @param types [Array<String>, nil] Filter to these singular type names
      # @param fields [Array<String>] Fields to search: "identifier", "metadata", "source_code"
      # @param limit [Integer] Maximum results to return
      # @return [Array<Hash>] Matches with :identifier, :type, :match_field keys
      def search(query, types: nil, fields: %w[identifier], limit: 20)
        pattern = Regexp.new(Regexp.escape(query), Regexp::IGNORECASE)
        results = []

        dirs = if types
                 types.filter_map { |t| TYPE_TO_DIR[t] }
               else
                 TYPE_DIRS
               end

        dirs.each do |dir|
          type_name = DIR_TO_TYPE[dir]
          entries = read_index(dir)

          entries.each do |entry|
            break if results.size >= limit

            id = entry['identifier']

            # Phase 1: identifier matching
            if fields.include?('identifier') && pattern.match?(id)
              results << { identifier: id, type: type_name, match_field: 'identifier' }
              next
            end

            # Phase 2: metadata/source_code matching (requires loading full unit)
            next unless fields.include?('metadata') || fields.include?('source_code')

            unit = find_unit(id)
            next unless unit

            if fields.include?('source_code') && unit['source_code'] && pattern.match?(unit['source_code'])
              results << { identifier: id, type: type_name, match_field: 'source_code' }
            elsif fields.include?('metadata') && unit['metadata'] && pattern.match?(unit['metadata'].to_json)
              results << { identifier: id, type: type_name, match_field: 'metadata' }
            end
          end
        end

        results.first(limit)
      end

      # BFS traversal of forward dependencies.
      #
      # @param identifier [String] Starting unit identifier
      # @param depth [Integer] Maximum traversal depth
      # @param types [Array<String>, nil] Filter to these singular type names
      # @return [Hash] { root:, nodes: { id => { type:, depth:, deps: [] } } }
      def traverse_dependencies(identifier, depth: 2, types: nil)
        traverse(identifier, depth: depth, types: types, direction: :forward)
      end

      # BFS traversal of reverse dependencies (dependents).
      #
      # @param identifier [String] Starting unit identifier
      # @param depth [Integer] Maximum traversal depth
      # @param types [Array<String>, nil] Filter to these singular type names
      # @return [Hash] { root:, nodes: { id => { type:, depth:, deps: [] } } }
      def traverse_dependents(identifier, depth: 2, types: nil)
        traverse(identifier, depth: depth, types: types, direction: :reverse)
      end

      # Search rails_source units by concept keyword.
      #
      # Matches the keyword (case-insensitive) against identifier, source_code,
      # and metadata fields of rails_source type units.
      #
      # @param keyword [String] Concept keyword to match (e.g. "ActiveRecord", "routing", "persistence")
      # @param limit [Integer] Maximum results to return
      # @return [Array<Hash>] Matching rails_source unit summaries
      def framework_sources(keyword, limit: 20)
        pattern = Regexp.new(Regexp.escape(keyword), Regexp::IGNORECASE)
        results = []

        entries = read_index('rails_source')
        entries.each do |entry|
          break if results.size >= limit

          id = entry['identifier']
          unit = find_unit(id)
          next unless unit

          matched = pattern.match?(id) ||
                    (unit['source_code'] && pattern.match?(unit['source_code'])) ||
                    (unit['metadata'] && pattern.match?(unit['metadata'].to_json))

          next unless matched

          results << {
            identifier: id,
            type: 'rails_source',
            file_path: unit['file_path'],
            metadata: unit['metadata']
          }
        end

        results
      end

      # Return units sorted by most recent git modification.
      #
      # Reads all units that have metadata.git.last_modified and returns
      # them sorted descending by that timestamp.
      #
      # @param limit [Integer] Maximum results to return
      # @param types [Array<String>, nil] Filter to these singular type names
      # @return [Array<Hash>] Units sorted by last_modified descending
      def recent_changes(limit: 10, types: nil)
        dirs = if types
                 types.filter_map { |t| TYPE_TO_DIR[t] }
               else
                 TYPE_DIRS
               end

        units_with_dates = []

        dirs.each do |dir|
          entries = read_index(dir)
          entries.each do |entry|
            id = entry['identifier']
            unit = find_unit(id)
            next unless unit

            last_modified = unit.dig('metadata', 'git', 'last_modified')
            next unless last_modified

            units_with_dates << {
              identifier: id,
              type: DIR_TO_TYPE[dir],
              file_path: unit['file_path'],
              last_modified: last_modified
            }
          end
        end

        units_with_dates
          .sort_by { |u| u[:last_modified] }
          .reverse
          .first(limit)
      end

      # @return [Hash] Raw dependency graph data from JSON
      def raw_graph_data
        @raw_graph_data ||= parse_json('dependency_graph.json')
      end

      private

      # Build identifier → { type_dir, filename } map from all _index.json files.
      def identifier_map
        @identifier_map ||= build_identifier_map
      end

      def build_identifier_map
        map = {}
        TYPE_DIRS.each do |dir|
          entries = read_index(dir)
          entries.each do |entry|
            id = entry['identifier']
            filename = "#{id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')}.json"
            map[id] = { type_dir: dir, filename: filename }
          end
        end
        map
      end

      # Read and cache an _index.json file for a type directory.
      def read_index(dir)
        @index_cache ||= {}
        @index_cache[dir] ||= begin
          path = @index_dir.join(dir, '_index.json')
          path.file? ? JSON.parse(path.read) : []
        end
      end

      # Load a unit JSON file with LRU cache eviction.
      def load_unit(type_dir, filename)
        cache_key = "#{type_dir}/#{filename}"

        if @unit_cache.key?(cache_key)
          # Move to end (most recently used)
          @unit_cache_order.delete(cache_key)
          @unit_cache_order.push(cache_key)
          return @unit_cache[cache_key]
        end

        path = @index_dir.join(type_dir, filename)
        return nil unless path.file?

        data = JSON.parse(path.read)

        # Evict oldest if at capacity
        if @unit_cache.size >= MAX_UNIT_CACHE
          oldest = @unit_cache_order.shift
          @unit_cache.delete(oldest)
        end

        @unit_cache[cache_key] = data
        @unit_cache_order.push(cache_key)
        data
      end

      # Parse a JSON file relative to the index directory.
      def parse_json(filename)
        path = @index_dir.join(filename)
        JSON.parse(path.read)
      end

      # BFS traversal in either direction.
      def traverse(identifier, depth:, types:, direction:)
        graph_data = raw_graph_data
        nodes_data = graph_data['nodes'] || {}

        return { root: identifier, found: false, nodes: {} } unless nodes_data.key?(identifier)

        type_set = types&.to_set
        visited = Set.new([identifier])
        queue = [[identifier, 0]]
        result_nodes = {}

        while queue.any?
          current, current_depth = queue.shift

          neighbors = if direction == :forward
                        (graph_data['edges'] || {})[current] || []
                      else
                        (graph_data['reverse'] || {})[current] || []
                      end

          # Filter by type if requested
          filtered = if type_set
                       neighbors.select do |n|
                         node_meta = nodes_data[n]
                         node_meta && type_set.include?(node_meta['type'])
                       end
                     else
                       neighbors
                     end

          node_meta = nodes_data[current]
          result_nodes[current] = {
            type: node_meta&.dig('type'),
            depth: current_depth,
            deps: filtered
          }

          next if current_depth >= depth

          filtered.each do |neighbor|
            unless visited.include?(neighbor)
              visited.add(neighbor)
              queue.push([neighbor, current_depth + 1])
            end
          end
        end

        { root: identifier, found: true, nodes: result_nodes }
      end
    end
  end
end
