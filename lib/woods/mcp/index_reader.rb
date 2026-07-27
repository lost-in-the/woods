# frozen_string_literal: true

require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/string/inflections'
require 'digest'
require 'json'
require 'pathname'
require 'set'

require_relative '../generation'

module Woods
  module MCP
    # Reads extraction output from disk for the MCP server.
    #
    # Lazy-loads unit JSON files on demand with an LRU-ish cache cap.
    # Builds an identifier index from _index.json files for fast lookups.
    #
    # @example
    #   reader = IndexReader.new("/path/to/woods")
    #   reader.find_unit("Post")      # => Hash (full unit data)
    #   reader.list_units(type: "model") # => Array<Hash>
    #
    class IndexReader
      # Directories that correspond to extractor types in the output.
      # Must stay in sync with Extractor::EXTRACTORS keys.
      TYPE_DIRS = %w[
        models controllers graphql components view_components
        services jobs mailers serializers managers policies validators
        concerns routes middleware i18n pundit_policies configurations
        engines view_templates migrations action_cable_channels
        scheduled_jobs rake_tasks state_machines events decorators
        database_views caching factories test_mappings rails_source
        poros libs
      ].freeze

      # Singular type name for each directory (used in search filtering).
      # Derived from TYPE_DIRS via ActiveSupport singularize — no manual sync needed.
      DIR_TO_TYPE = TYPE_DIRS.to_h { |dir| [dir, dir.singularize] }.freeze

      TYPE_TO_DIR = DIR_TO_TYPE.invert.freeze

      # Maximum number of loaded unit files to cache in memory.
      MAX_UNIT_CACHE = 50

      # @param index_dir [String] Path to extraction output directory
      # @param auto_refresh [Boolean] re-read the index when its published
      #   generation moves. On by default; specs that assert caching behaviour
      #   turn it off.
      # @raise [ArgumentError] if directory doesn't exist or has no manifest.json
      def initialize(index_dir, auto_refresh: true)
        @index_dir = Pathname.new(index_dir)
        raise ArgumentError, "Index directory does not exist: #{index_dir}" unless @index_dir.directory?
        raise ArgumentError, "No manifest.json found in: #{index_dir}" unless @index_dir.join('manifest.json').file?

        @unit_cache = {}
        @unit_cache_order = []
        @identifier_map = nil
        @auto_refresh = auto_refresh
        @pinned = false
        @generation = Woods::Generation.new(output_dir: @index_dir)
        @loaded_generation = nil
        @generation_signature = nil
      end

      # The generation this reader's caches were populated from.
      #
      # @return [Integer, nil] nil until something has been read
      attr_reader :loaded_generation

      # Drop caches if the index has been rewritten since they were populated.
      #
      # This is what makes the MCP `reload` tool an optimization rather than a
      # correctness requirement. A long-lived server used to hold whatever it
      # read at boot until someone thought to call `reload` — so an agent
      # working alongside a running extraction got answers describing the tree
      # as of the last time the server happened to start.
      #
      # Called at the top of every public read. The cost is one `File.stat` of
      # a ~100-byte file; the file is only parsed when its mtime or size moved,
      # and the caches are only dropped when the generation number actually
      # advanced. An index with no generation file (written before generations
      # existed, or by a third party) never refreshes — same behaviour as
      # before.
      #
      # @return [Integer, nil] the generation now loaded, or nil when the
      #   caches were already current
      def ensure_fresh!
        return nil unless @auto_refresh
        return nil if @pinned

        signature = generation_signature
        return nil if signature.nil? || signature == @generation_signature

        @generation_signature = signature
        published = @generation.current.number
        return nil if published.zero? || published == @loaded_generation

        reload!
        @loaded_generation = published
      end

      # Suppress cache invalidation for the duration of a block.
      #
      # {#ensure_fresh!} runs per read, which bounds staleness but does not
      # make a *sequence* of reads consistent: a caller that reads the manifest
      # and then a unit can straddle two generations if a write lands between
      # them. Both halves describe a real state of the tree, but not the same
      # one.
      #
      # Wrapping a multi-read operation checks freshness once, up front, and
      # then holds it — so nothing already cached is dropped and re-read at a
      # newer generation partway through.
      #
      # **What this does not do:** an artifact that has never been read is
      # still loaded from whatever is on disk when the block reaches it.
      # Guaranteeing more would mean materializing the whole index on entry,
      # which is what {#warmup!} costs, per request. Closing that last gap
      # properly needs the payload behind an atomic pointer — see
      # docs/WATCH_DAEMON.md.
      #
      # @example
      #   reader.with_pinned_generation { [reader.manifest, reader.find_unit("Post")] }
      #
      # @yield the block to run against a single generation
      # @return [Object] the block's value
      def with_pinned_generation
        return yield if @pinned

        ensure_fresh!
        @pinned = true
        begin
          yield
        ensure
          @pinned = false
        end
      end

      # Pre-populate cached state so the first MCP tool call doesn't pay
      # for disk reads + JSON parsing.
      #
      # Touches every lazy accessor: manifest, summary, dependency_graph,
      # graph_analysis, and the identifier_map (which reads all _index.json
      # files). Each step is individually rescued so a missing optional
      # artefact (e.g. graph_analysis.json) never blocks the rest.
      #
      # Safe to call multiple times — lazy accessors short-circuit on the
      # memoized value.
      #
      # @return [Hash] Per-step outcome: `{step => true | Exception}`
      def warmup!
        with_pinned_generation { warmup_steps }
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
        @normalized_graph_edges = nil
      end

      # @return [Hash] Parsed manifest.json
      def manifest
        ensure_fresh!
        @manifest ||= parse_json('manifest.json')
      end

      # Template engines the extraction pipeline currently understands.
      # Delegates to {ViewTemplateExtractor.supported_template_engines} so
      # the list stays honest as engines are added or removed. Surfaced by
      # the MCP `structure` tool (#86).
      #
      # @return [Array<Symbol>]
      def template_engines
        require_relative '../extractors/view_template_extractor'
        Woods::Extractors::ViewTemplateExtractor.supported_template_engines.dup
      end

      # @return [String, nil] SUMMARY.md content, or nil if not present
      def summary
        ensure_fresh!
        @summary ||= begin
          path = @index_dir.join('SUMMARY.md')
          path.file? ? path.read : nil
        end
      end

      # @return [Woods::DependencyGraph] Graph loaded from disk
      def dependency_graph
        ensure_fresh!
        @dependency_graph ||= begin
          data = parse_json('dependency_graph.json')
          Woods::DependencyGraph.from_h(data)
        end
      end

      # @return [Hash] Parsed graph_analysis.json
      def graph_analysis
        ensure_fresh!
        @graph_analysis ||= parse_json('graph_analysis.json')
      end

      # Find a single unit by identifier.
      #
      # @param identifier [String] Unit identifier (e.g. "Post", "Api::V1::HealthController")
      # @return [Hash, nil] Full unit data or nil if not found
      def find_unit(identifier)
        ensure_fresh!
        location = identifier_map[identifier]
        return nil unless location

        load_unit(location[:type_dir], location[:filename])
      end

      # List units, optionally filtered by type.
      #
      # @param type [String, nil] Singular type name (e.g. "model", "controller")
      # @return [Array<Hash>] Index entries for matching units
      def list_units(type: nil)
        ensure_fresh!
        dirs = if type
                 dir = TYPE_TO_DIR[type]
                 dir ? [dir] : []
               else
                 TYPE_DIRS
               end

        dirs.flat_map { |dir| read_index(dir) }
      end

      # Default maximum number of unit files to load during phase-2 search.
      # Override with WOODS_SEARCH_MAX_SCAN env var.
      DEFAULT_SEARCH_MAX_SCAN = 500

      # Search units by case-insensitive pattern.
      #
      # Phase 1: match identifiers from index files (cheap).
      # Phase 2: lazy-load unit files for metadata/source_code matching.
      #
      # The query is compiled as a raw Ruby regex with IGNORECASE. If the pattern
      # is invalid, it falls back to an escaped literal match.
      #
      # A "broad" pattern is one that matches more than 50% of the entries in a
      # type directory. Broad patterns still run but the result includes a :note.
      #
      # Phase-2 scan is capped at WOODS_SEARCH_MAX_SCAN unit files (default 500).
      # When the cap is reached the result includes :partial => true.
      #
      # The optional +exact_prefix+ / +exact_suffix+ filters restrict results to
      # identifiers whose start/end matches the given string literally (case-
      # insensitive). They are ANDed with the +query+ regex and are safer than
      # hand-escaping regex anchors — metacharacters like +::+ are treated as
      # literal text.
      #
      # @param query [String, nil] Search pattern (case-insensitive regex). Optional when
      #   +exact_prefix+ or +exact_suffix+ is provided; otherwise required.
      # @param types [Array<String>, nil] Filter to these singular type names
      # @param fields [Array<String>] Fields to search: "identifier", "metadata", "source_code"
      # @param limit [Integer] Maximum results to return
      # @param exact_prefix [String, nil] Literal identifier prefix filter (case-insensitive)
      # @param exact_suffix [String, nil] Literal identifier suffix filter (case-insensitive)
      # @return [Hash] { results: Array<Hash>, note: String|nil, partial: Boolean }
      # @raise [ArgumentError] when all of query, exact_prefix, and exact_suffix are blank
      def search(query = nil, types: nil, fields: %w[identifier], limit: 20, exact_prefix: nil, exact_suffix: nil)
        ensure_fresh!
        prefix = exact_prefix.blank? ? nil : exact_prefix.downcase
        suffix = exact_suffix.blank? ? nil : exact_suffix.downcase
        if query.blank? && !prefix && !suffix
          raise ArgumentError, 'search requires a query or exact_prefix/exact_suffix filter'
        end

        # When only prefix/suffix are provided, the regex acts as a match-all
        # wildcard so the existing phase-1/phase-2 pipeline still works.
        pattern = compile_search_pattern(query.to_s.empty? ? '.*' : query)
        max_scan_env = ENV.fetch('WOODS_SEARCH_MAX_SCAN', '').to_s.strip
        max_scan = max_scan_env.empty? ? DEFAULT_SEARCH_MAX_SCAN : max_scan_env.to_i
        max_scan = DEFAULT_SEARCH_MAX_SCAN if max_scan <= 0

        results = []
        notes = []
        phase2_scanned = 0
        partial = false

        dirs = if types
                 types.filter_map { |t| TYPE_TO_DIR[t] }
               else
                 TYPE_DIRS
               end

        # Phase 2 candidates are collected per-dir and then scanned in
        # round-robin across dirs. Exhausting the per-run scan cap linearly
        # down TYPE_DIRS order would starve later types (`concerns` at pos
        # 13, `test_mappings` at pos 31) on any codebase where the earlier
        # dirs together exceed max_scan entries. Interleaving guarantees
        # every type contributes to the scanned set.
        phase2_queues = {}

        dirs.each do |dir|
          type_name = DIR_TO_TYPE[dir]
          entries = read_index(dir)

          # Broad-match detection: warn when pattern matches >50% of dir entries
          if entries.size > 1
            matching_count = entries.count do |e|
              identifier_passes_filters?(e['identifier'], pattern, prefix, suffix)
            end
            if matching_count > entries.size / 2.0
              notes << "broad pattern matched #{matching_count}/#{entries.size} entries in #{dir}"
            end
          end

          entries.each do |entry|
            id = entry['identifier']
            next unless identifier_passes_prefix_suffix?(id, prefix, suffix)

            # Phase 1: identifier matching (still in-order per dir)
            if fields.include?('identifier') && pattern.match?(id)
              next if results.size >= limit

              results << { identifier: id, type: type_name, match_field: 'identifier' }
              next
            end

            # Phase 2 is only reached when the caller opted into deeper fields.
            next unless fields.include?('metadata') || fields.include?('source_code')

            (phase2_queues[dir] ||= []) << [type_name, id]
          end
        end

        if results.size < limit && phase2_queues.any?
          queues = phase2_queues.values.map(&:dup)
          catch(:phase2_done) do
            loop do
              progressed = false
              queues.each do |queue|
                next if queue.empty?

                throw :phase2_done if results.size >= limit

                if phase2_scanned >= max_scan
                  partial = true
                  throw :phase2_done
                end

                type_name, id = queue.shift
                progressed = true

                unit = find_unit(id)
                next unless unit

                phase2_scanned += 1

                if fields.include?('source_code') && unit['source_code'] && pattern.match?(unit['source_code'])
                  results << { identifier: id, type: type_name, match_field: 'source_code' }
                elsif fields.include?('metadata') && unit['metadata'] && pattern.match?(unit['metadata'].to_json)
                  results << { identifier: id, type: type_name, match_field: 'metadata' }
                end
              end
              break unless progressed
            end
          end
        end

        response = { results: results.first(limit) }
        response[:note] = notes.join('; ') unless notes.empty?
        response[:partial] = true if partial
        response
      end

      # BFS traversal of forward dependencies.
      #
      # @param identifier [String] Starting unit identifier
      # @param depth [Integer] Maximum traversal depth
      # @param types [Array<String>, nil] Filter to these singular type names
      # @param via [Array<String>, nil] Filter to these relationship types (e.g. ["link_to", "redirect_to"])
      # @return [Hash] { root:, nodes: { id => { type:, depth:, deps: [] } } }
      def traverse_dependencies(identifier, depth: 2, types: nil, via: nil)
        traverse(identifier, depth: depth, types: types, via: via, direction: :forward)
      end

      # BFS traversal of reverse dependencies (dependents).
      #
      # @param identifier [String] Starting unit identifier
      # @param depth [Integer] Maximum traversal depth
      # @param types [Array<String>, nil] Filter to these singular type names
      # @param via [Array<String>, nil] Filter to these relationship types (e.g. ["link_to", "redirect_to"])
      # @return [Hash] { root:, nodes: { id => { type:, depth:, deps: [] } } }
      def traverse_dependents(identifier, depth: 2, types: nil, via: nil)
        traverse(identifier, depth: depth, types: types, via: via, direction: :reverse)
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
        ensure_fresh!
        # Multi-word keywords ("ActiveRecord callbacks") are split on
        # whitespace and ANDed. Single-word queries behave as before.
        tokens = keyword.to_s.strip.split(/\s+/)
        return [] if tokens.empty?

        patterns = tokens.map { |t| Regexp.new(Regexp.escape(t), Regexp::IGNORECASE) }
        results = []

        entries = read_index('rails_source')
        entries.each do |entry|
          break if results.size >= limit

          id = entry['identifier']
          unit = find_unit(id)
          next unless unit

          metadata_json = unit['metadata']&.to_json
          matched = patterns.all? do |pat|
            pat.match?(id) ||
              (unit['source_code'] && pat.match?(unit['source_code'])) ||
              (metadata_json && pat.match?(metadata_json))
          end

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
        ensure_fresh!
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
              last_modified: last_modified,
              author: unit.dig('metadata', 'git', 'last_author')
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
        ensure_fresh!
        @raw_graph_data ||= parse_json('dependency_graph.json')
      end

      private

      # Touch every lazy accessor, recording rather than raising per-step
      # failures so a missing optional artefact (graph_analysis.json on an index
      # written before it existed) never blocks the rest.
      #
      # @return [Hash] `{step => true | Exception}`
      def warmup_steps
        steps = {
          manifest: -> { manifest },
          summary: -> { summary },
          dependency_graph: -> { dependency_graph },
          graph_analysis: -> { graph_analysis },
          identifier_map: -> { identifier_map }
        }
        steps.each_with_object({}) do |(step, runner), result|
          runner.call
          result[step] = true
        rescue StandardError => e
          result[step] = e
        end
      end

      # Compile a case-insensitive regex from a query string.
      #
      # Treats the query as a raw Ruby regex pattern. Falls back to an escaped
      # literal match (with a :note field added by callers) when the pattern is
      # invalid.
      #
      # @param query [String] Raw regex pattern
      # @return [Regexp] Compiled case-insensitive pattern
      def compile_search_pattern(query)
        Regexp.new(query, Regexp::IGNORECASE)
      rescue RegexpError
        Regexp.new(Regexp.escape(query), Regexp::IGNORECASE)
      end

      # A cheap stand-in for "has the generation file been rewritten?", so the
      # common case costs one `File.stat` of a ~100-byte file instead of a parse.
      #
      # The inode is load-bearing, not belt-and-braces. `[mtime, size]` alone
      # misses a bump whenever two writes land in the same mtime tick with the
      # same payload length — and equal length is the daemon's *steady state*:
      # reason `"incremental"` every cycle, fixed-width number and timestamp.
      # Coarse mtime granularity is not exotic either; it includes the
      # volume-mounted Docker deployment the Index Server is documented for. The
      # reader would then serve a stale index indefinitely, which is the exact
      # silent staleness generations exist to end.
      #
      # {AtomicFile} renames a fresh Tempfile over the target on every write, so
      # a new inode is guaranteed per publish and this costs nothing extra.
      #
      # @return [Array, nil] opaque signature, or nil when there is no
      #   generation file
      def generation_signature
        stat = File.stat(@generation.path)
        [stat.mtime.to_f, stat.size, stat.ino]
      rescue SystemCallError
        nil
      end

      # Case-insensitive literal prefix/suffix check on an identifier.
      # Nil filters are treated as "no restriction".
      def identifier_passes_prefix_suffix?(identifier, prefix, suffix)
        return false unless identifier

        downcased = identifier.downcase
        return false if prefix && !downcased.start_with?(prefix)
        return false if suffix && !downcased.end_with?(suffix)

        true
      end

      # Combined regex + prefix/suffix check used only by broad-match detection,
      # which reports how many identifiers would actually surface.
      def identifier_passes_filters?(identifier, pattern, prefix, suffix)
        return false unless identifier_passes_prefix_suffix?(identifier, prefix, suffix)

        pattern.match?(identifier)
      end

      # Memoized normalized edges — converts bare strings (old format) to hashes once.
      # Cleared by reload! alongside raw_graph_data.
      def normalized_graph_edges
        @normalized_graph_edges ||= normalize_all_edges(raw_graph_data['edges'] || {})
      end

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
            base = id.gsub('::', '__').gsub(/[^a-zA-Z0-9_-]/, '_')
            digest = Digest::SHA256.hexdigest(id)[0, 8]
            filename = "#{base}_#{digest}.json"
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
      #
      # Edges may be stored as bare strings (old format) or as
      # +{"target" => "...", "via" => "..."}+ hashes (new format).
      # This method handles both transparently.
      #
      # @param identifier [String] Starting unit identifier
      # @param depth [Integer] Maximum traversal depth
      # @param types [Array<String>, nil] Filter to these unit type names
      # @param via [Array<String>, nil] Filter to these relationship types
      # @param direction [:forward, :reverse] Traversal direction
      # @return [Hash]
      def traverse(identifier, depth:, types:, via:, direction:)
        graph_data = raw_graph_data
        nodes_data = graph_data['nodes'] || {}

        return { root: identifier, found: false, nodes: {} } unless nodes_data.key?(identifier)

        # Normalize edges once per graph load — memoized alongside raw_graph_data
        normalized_edges = normalized_graph_edges

        type_set = types&.to_set
        via_set = via&.to_set
        visited = Set.new([identifier])
        queue = [[identifier, 0]]
        result_nodes = {}

        while queue.any?
          current, current_depth = queue.shift

          neighbors = if direction == :forward
                        resolve_forward_neighbors(normalized_edges, current, via_set)
                      else
                        resolve_reverse_neighbors(graph_data, normalized_edges, current, via_set)
                      end

          # Filter by node type if requested
          filtered = if type_set
                       neighbors.select do |n|
                         node_meta = nodes_data[n]
                         node_meta && type_set.include?(node_meta['type'])
                       end
                     else
                       neighbors
                     end

          # At max depth, record the node with empty deps so the renderer
          # doesn't emit an extra level of unexpanded neighbors. The parent
          # node's deps list already shows this node as a child.
          will_expand = current_depth < depth
          node_meta = nodes_data[current]
          result_nodes[current] = {
            type: node_meta&.dig('type'),
            depth: current_depth,
            deps: will_expand ? filtered : []
          }

          next unless will_expand

          filtered.each do |neighbor|
            unless visited.include?(neighbor)
              visited.add(neighbor)
              queue.push([neighbor, current_depth + 1])
            end
          end
        end

        { root: identifier, found: true, nodes: result_nodes }
      end

      # Normalize all edge arrays once, converting bare strings to hashes.
      #
      # NOTE: This uses string keys ('target', 'via') because IndexReader
      # operates on parsed JSON. DependencyGraph.normalize_edges uses symbol
      # keys (:target, :via) for in-memory Ruby objects. The two normalizers
      # are intentionally separate — do not merge them.
      #
      # @param raw_edges [Hash] Raw edges from graph JSON
      # @return [Hash] Edges with all entries as { 'target' => ..., 'via' => ... } hashes
      def normalize_all_edges(raw_edges)
        raw_edges.transform_values do |entries|
          entries.map { |e| e.is_a?(Hash) ? e : { 'target' => e } }
        end
      end

      # Extract forward neighbor identifiers, optionally filtered by via type.
      # Expects pre-normalized edges (all entries are hashes).
      def resolve_forward_neighbors(normalized_edges, identifier, via_set)
        edges = normalized_edges[identifier] || []
        edges = edges.select { |e| via_set.include?(e['via']) } if via_set
        edges.map { |e| e['target'] }
      end

      # Extract reverse neighbor identifiers, optionally filtered by via type.
      # Reverse edges are stored as bare identifier arrays. When via filtering
      # is requested, checks each dependent's pre-normalized forward edges to
      # find those pointing at +identifier+ with a matching via type.
      def resolve_reverse_neighbors(graph_data, normalized_edges, identifier, via_set)
        dependents = (graph_data['reverse'] || {})[identifier] || []
        return dependents unless via_set

        dependents.select do |dep|
          forward = normalized_edges[dep] || []
          forward.any? { |e| e['target'] == identifier && via_set.include?(e['via']) }
        end
      end
    end
  end
end
