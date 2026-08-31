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
        poros libs ruby_classes ruby_modules ruby_methods ruby_files
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
        raise ArgumentError, "No manifest.json found in: #{index_dir}" unless manifest_present?

        @unit_cache = {}
        @unit_cache_signatures = {}
        @unit_cache_order = []
        @identifier_map = nil
        @auto_refresh = auto_refresh
        @pin_depth = 0
        @pin_owners = Hash.new(0)
        @exclusive_waiters = 0
        @exclusive_owner = nil
        @freshness_mutex = Mutex.new
        @freshness_condition = ConditionVariable.new
        # Separate from @freshness_mutex: the LRU bookkeeping must not
        # serialize behind a generation check, and a reader that took the
        # freshness lock must be able to touch the caches without deadlocking.
        @cache_mutex = Mutex.new
        @generation = Woods::Generation.new(output_dir: @index_dir)
        @loaded_generation = nil
        @loaded_token = nil
        @generation_signature = nil
        # The directory the loaded generation's payload lives in. nil until a
        # generation naming a payload is loaded; {#payload_dir} then falls back
        # to the index root, which is every flat/pre-pointer index.
        @payload_dir = nil
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
      # The check-and-reload is a mutex-guarded critical section. The stdio
      # transport serializes tool calls, but `woods-mcp-http` runs handlers on
      # its Rack server's request threads — and unguarded, two concurrent reads
      # race the signature bookkeeping: duplicate `reload!`s, or one request's
      # freshly populated caches dropped mid-sequence by the other's refresh.
      #
      # @return [Integer, nil] the generation now loaded, or nil when the
      #   caches were already current
      def ensure_fresh!
        return nil unless @auto_refresh

        thread = Thread.current
        @freshness_mutex.synchronize do
          wait_for_generation_access(thread)
          refresh_if_stale
        end
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
      # **What this does not do on a flat index:** an artifact that has never
      # been read is loaded from whatever is on disk when the block reaches it.
      # Guaranteeing more would mean materializing the whole index on entry,
      # which is what {#warmup!} costs, per request. When the loaded generation
      # names an immutable payload directory (its {Woods::Generation} carries a
      # +payload+ pointer), that gap is closed for free: every read in the
      # block resolves through {#payload_dir}, which is fixed at pin entry and
      # names one immutable snapshot, so a never-read artifact still comes from
      # the pinned generation even as a newer payload is published. A flat
      # index carries no pointer and keeps the old behaviour — see
      # docs/WATCH_DAEMON.md.
      #
      # Pins are *refcounted*, not a boolean. Under a threaded transport two
      # requests can hold pins at once, and with a boolean the first to finish
      # unpinned the reader while the second still relied on it — its remaining
      # reads could then be invalidated mid-sequence, the exact tear this
      # method exists to prevent. Freshness is checked only when the depth goes
      # 0 → 1; nested and overlapping pins ride the generation already held,
      # and invalidation resumes when the last pin releases.
      #
      # The Index MCP server applies this around reader-backed handlers. Direct
      # IndexReader callers remain responsible for pinning any multi-read
      # operation that must not refresh between accessors.
      #
      # @example
      #   reader.with_pinned_generation { [reader.manifest, reader.find_unit("Post")] }
      #
      # @yield the block to run against a single generation
      # @return [Object] the block's value
      def with_pinned_generation
        thread = Thread.current
        exclusive_owner = false
        @freshness_mutex.synchronize do
          if @exclusive_owner.equal?(thread)
            exclusive_owner = true
          else
            wait_for_generation_access(thread)
            refresh_if_stale if @auto_refresh && @pin_depth.zero?
            @pin_depth += 1
            @pin_owners[thread] += 1
          end
        end

        begin
          yield
        ensure
          release_generation_pin(thread) unless exclusive_owner
        end
      end

      # Reload all cached index state while excluding pinned readers.
      #
      # Existing pins may finish and nest normally. Once an exclusive reload is
      # waiting, new pins wait until the reload block has assembled its result.
      #
      # @yieldparam manifest [Hash] the manifest loaded after caches are cleared
      # @return [Object] the block's value
      # @raise [ThreadError] when upgrading a pin or nesting an exclusive reload
      def with_exclusive_reload
        with_exclusive_generation do
          reload!
          yield manifest
        end
      end

      # Hold the exclusive generation lock WITHOUT refreshing anything.
      #
      # This is the swap lock the reload transaction (M7) acquires after its
      # candidate stores are built off-side. Inside the block the caller
      # rechecks the generation and then swaps atomically; the reader's own
      # caches are reloaded by the caller ONLY after the recheck passes, so a
      # failed recheck leaves the previous fully aligned generation untouched.
      # {#with_exclusive_reload} is this lock plus the unconditional reload.
      #
      # Waiters follow the same rules as {#with_exclusive_reload}: in-flight
      # pins finish before the block runs, and new pins wait while it is held.
      #
      # @yield no arguments
      # @return [Object] the block's value
      # @raise [ThreadError] when upgrading a pin or nesting an exclusive lock
      def with_exclusive_generation
        thread = Thread.current
        acquire_exclusive_generation(thread)

        begin
          yield
        ensure
          release_exclusive_generation(thread)
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
        @cache_mutex.synchronize do
          @unit_cache = {}
          @unit_cache_signatures = {}
          @unit_cache_order = []
        end
        @identifier_map = nil
        @index_cache = {}
        @manifest = nil
        @summary = nil
        @dependency_graph = nil
        @graph_analysis = nil
        @raw_graph_data = nil
        @normalized_graph_edges = nil
        @graph_node_types = nil
      end

      # The directory the current read resolves payload artifacts against —
      # manifest, summary, graph, per-type indexes, unit files and precomputed
      # flows. It is the immutable payload directory the loaded generation
      # names, or the index root for a flat/pre-pointer index.
      #
      # Fixed for the life of a pin (only {#refresh_if_stale} moves it, and
      # pins suppress refresh), so every artifact of a pinned read resolves
      # through one generation. Public because callers that read payload files
      # without going through this reader — the flow assembler, the
      # precomputed-flow loader — have to resolve to the same generation this
      # reader is serving, not to whatever is published when they look.
      #
      # @return [Pathname]
      def payload_dir
        ensure_fresh!
        current_payload_dir
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
          path = current_payload_dir.join('SUMMARY.md')
          path.file? ? read_utf8(path) : nil
        end
      end

      # @return [Woods::DependencyGraph] Graph loaded from disk
      def dependency_graph
        ensure_fresh!
        @dependency_graph ||= Woods::DependencyGraph.from_h(raw_graph_data)
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

      # Wall-clock budget for a single match against the user-supplied search
      # pattern (audit P5). The query is compiled as a raw Ruby regex; a
      # pattern with catastrophic backtracking would otherwise stall the
      # dispatch thread indefinitely. Ruby 3.2+ can enforce a per-match limit
      # at the engine level (Regexp.new(timeout:)); on older Rubies the
      # pattern compiles without one and this constant is unused.
      SEARCH_PATTERN_TIMEOUT = 1.0

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
        # Pinned, not merely checked-once. This walks the identifier map and
        # then loads units for the hits; each nested `find_unit` re-checks
        # freshness, so a publish landing mid-walk rebuilt the caches while the
        # result list still held identifiers from the previous generation — one
        # response describing two indexes.
        with_pinned_generation do
          search_within_pin(query, types: types, fields: fields, limit: limit,
                                   exact_prefix: exact_prefix, exact_suffix: exact_suffix)
        end
      end

      # @api private
      def search_within_pin(query = nil, types: nil, fields: %w[identifier], limit: 20,
                            exact_prefix: nil, exact_suffix: nil)
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

        begin
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
        rescue Regexp::TimeoutError
          notes << "search aborted: the pattern exceeded the #{SEARCH_PATTERN_TIMEOUT}s per-match limit"
          partial = true
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
        with_pinned_generation { framework_sources_within_pin(keyword, limit: limit) }
      end

      # @api private
      def framework_sources_within_pin(keyword, limit: 20)
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
        with_pinned_generation { recent_changes_within_pin(limit: limit, types: types) }
      end

      # @api private
      def recent_changes_within_pin(limit: 10, types: nil)
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
      #
      # The single parse point for dependency_graph.json per generation
      # (audit P6): {#dependency_graph} builds the typed graph from this
      # same hash (DependencyGraph.from_h does not mutate its input), so a
      # generation that touches both accessors holds one parsed copy.
      #
      # CONTRACT: the returned hash (and everything nested in it) is SHARED
      # state across every accessor and consumer for this generation. Treat
      # it as read-only: mutating it corrupts {#dependency_graph} and the
      # memoized edge normalization. Every current consumer (server graph
      # tools, obsidian exporter, internal normalizers) is verified
      # read-only; a new consumer that needs to mutate must deep-dup first.
      def raw_graph_data
        ensure_fresh!
        @raw_graph_data ||= parse_json('dependency_graph.json')
      end

      private

      def wait_for_generation_access(thread)
        @freshness_condition.wait(@freshness_mutex) while generation_access_blocked?(thread)
      end

      def generation_access_blocked?(thread)
        return false if @exclusive_owner.equal?(thread) || @pin_owners.key?(thread)

        !@exclusive_owner.nil? || @exclusive_waiters.positive?
      end

      def release_generation_pin(thread)
        @freshness_mutex.synchronize do
          @pin_depth -= 1
          @pin_owners[thread] -= 1
          @pin_owners.delete(thread) if @pin_owners[thread].zero?
          @freshness_condition.broadcast if @pin_depth.zero?
        end
      end

      def acquire_exclusive_generation(thread)
        @freshness_mutex.synchronize do
          raise ThreadError, 'Cannot start an exclusive reload from a pinned generation' if @pin_owners.key?(thread)
          raise ThreadError, 'This thread already owns an exclusive reload' if @exclusive_owner.equal?(thread)

          @exclusive_waiters += 1
          begin
            @freshness_condition.wait(@freshness_mutex) until @pin_depth.zero? && @exclusive_owner.nil?
            @exclusive_owner = thread
          ensure
            @exclusive_waiters -= 1
            @freshness_condition.broadcast
          end
        end
      end

      def release_exclusive_generation(thread)
        @freshness_mutex.synchronize do
          @exclusive_owner = nil if @exclusive_owner.equal?(thread)
          @freshness_condition.broadcast
        end
      end

      # The body of {#ensure_fresh!}. Callers must hold `@freshness_mutex`; it
      # is split out so {#with_pinned_generation} can run it inside the same
      # critical section that increments the pin depth.
      #
      # @return [Integer, nil] the generation now loaded, or nil when the
      #   caches were already current
      def refresh_if_stale
        return nil if @pin_depth.positive?

        signature = generation_signature
        return nil if signature.nil? || signature == @generation_signature

        @generation_signature = signature
        marker = @generation.current
        return nil if marker.number.zero? || same_generation?(marker)

        reload!
        @payload_dir = resolve_payload_dir(marker)
        @loaded_token = marker.token
        @loaded_generation = marker.number
      end

      # Is there an index here at all?
      #
      # A flat index answers with the manifest at the root. An index that
      # publishes per-generation payloads has no manifest there — every payload
      # artifact lives in the directory the published generation names — so the
      # pointer is followed before concluding the directory is not an index.
      #
      # @return [Boolean]
      def manifest_present?
        return true if @index_dir.join('manifest.json').file?

        marker = Woods::Generation.new(output_dir: @index_dir).current
        resolve_payload_dir(marker).join('manifest.json').file?
      end

      # The loaded generation's payload directory, without a freshness check.
      #
      # Internal reads call this rather than {#payload_dir}: they are already
      # inside a public read that checked freshness once, and re-checking per
      # artifact would take the freshness mutex and stat generation.json for
      # every unit file a request touches.
      #
      # @return [Pathname]
      def current_payload_dir
        @payload_dir || @index_dir
      end

      # Resolve a generation's payload pointer to an on-disk directory.
      #
      # Delegates to {Woods::Generation#payload_dir} so every reader of a
      # payload artifact — the exporters, the validator, the daemon and this
      # reader — follows the pointer by exactly the same rules.
      #
      # @param marker [Woods::Generation::Marker]
      # @return [Pathname]
      def resolve_payload_dir(marker)
        Woods::Generation.new(output_dir: @index_dir).payload_dir(marker)
      end

      # Compare the *token*, not the number.
      #
      # `bump!` is a read-modify-write, so two writers that overlap can both
      # publish the same number — which the design permits, since a manual rake
      # run proceeds after waiting for the lock. A reader already loaded at N+1
      # would then see `published == loaded`, conclude it was current, and hold
      # caches describing the *other* writer's N+1 indefinitely: a stale index
      # that believes it is fresh, which is the one failure generations exist to
      # prevent.
      #
      # The token is a fresh random value per publish, so it distinguishes two
      # collapsed bumps that the counter cannot. Falls back to the number for
      # generation files written before tokens existed.
      def same_generation?(marker)
        return @loaded_generation == marker.number if marker.token.nil?

        @loaded_token == marker.token
      end

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
      # The compiled pattern carries the {SEARCH_PATTERN_TIMEOUT} per-match
      # wall-clock limit on Ruby 3.2+: a pattern with catastrophic
      # backtracking raises Regexp::TimeoutError on its first overrun instead
      # of stalling the dispatch thread indefinitely, which {#search_within_pin}
      # converts into a partial response.
      #
      # @param query [String] Raw regex pattern
      # @return [Regexp] Compiled case-insensitive pattern
      def compile_search_pattern(query)
        compile_case_insensitive_pattern(query)
      rescue RegexpError
        compile_case_insensitive_pattern(Regexp.escape(query))
      end

      # @param pattern [String] Regex source (already escaped when falling back)
      # @return [Regexp]
      def compile_case_insensitive_pattern(pattern)
        if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2')
          Regexp.new(pattern, Regexp::IGNORECASE, timeout: SEARCH_PATTERN_TIMEOUT)
        else
          Regexp.new(pattern, Regexp::IGNORECASE)
        end
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
      #
      # `edges` holds one type's edges per identifier. Where an identifier
      # names units of several types the rest live in `variants`, and a
      # traversal that read only the primary would report a unit as having no
      # dependencies at all. They are unioned here so traversal follows the
      # identifier's whole out-edge set.
      def normalized_graph_edges
        @normalized_graph_edges ||= begin
          edges = normalize_all_edges(raw_graph_data['edges'] || {})
          variant_records.each do |record|
            identifier = record['identifier']
            next unless identifier

            extra = normalize_all_edges(identifier => Array(record['edges']))
            edges[identifier] = ((edges[identifier] || []) + extra[identifier]).uniq
          end
          edges
        end
      end

      # Every unit type registered under each identifier, sorted.
      #
      # One entry for all but the handful of identifiers a codebase reuses
      # across types; those get one per coexisting unit.
      #
      # @return [Hash{String => Array<String>}]
      def graph_node_types
        @graph_node_types ||= begin
          types = (raw_graph_data['nodes'] || {}).transform_values { |node| [node['type']].compact }
          variant_records.each do |record|
            identifier = record['identifier']
            next unless identifier && record['type']

            (types[identifier] ||= []) << record['type']
          end
          types.transform_values { |list| list.uniq.sort }
        end
      end

      # @return [Array<Hash>] the graph's `variants` section, empty when the
      #   graph has no identifier shared across types (and for every graph
      #   written before the section existed)
      def variant_records
        records = raw_graph_data['variants']
        records.is_a?(Array) ? records.grep(Hash) : []
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
          path = current_payload_dir.join(dir, '_index.json')
          path.file? ? JSON.parse(read_utf8(path)) : []
        end
      end

      # Load a unit JSON file with LRU cache eviction.
      #
      # The bookkeeping runs under {@cache_mutex}; the file read deliberately
      # does not, so concurrent readers still parse different units in
      # parallel. `woods-mcp-http` executes tool handlers on its Rack server's
      # request threads, and unsynchronized bookkeeping drifts: two threads
      # can both observe `size >= MAX_UNIT_CACHE` and both evict, or both push
      # the same key so the order array accumulates a duplicate. A duplicate
      # for a key never read again is never cleaned up (only a cache *hit*
      # dedupes it), so `shift` starts evicting keys that are no longer in the
      # cache and the cache creeps past its cap — a slow leak rather than a
      # wrong answer, but a leak.
      #
      # Values are unaffected either way: both threads parse the same file.
      def load_unit(type_dir, filename)
        cache_key = "#{type_dir}/#{filename}"
        path = current_payload_dir.join(type_dir, filename)
        open_unit(path.to_s) do |file|
          signature = unit_file_signature(file.stat)
          cached = @cache_mutex.synchronize do
            if @unit_cache.key?(cache_key) && @unit_cache_signatures[cache_key] == signature
              # Move to end (most recently used)
              @unit_cache_order.delete(cache_key)
              @unit_cache_order.push(cache_key)
              @unit_cache[cache_key]
            elsif @unit_cache.key?(cache_key)
              @unit_cache.delete(cache_key)
              @unit_cache_signatures.delete(cache_key)
              @unit_cache_order.delete(cache_key)
              nil
            end
          end
          return cached if cached

          data = JSON.parse(file.read)

          @cache_mutex.synchronize do
            # Evict oldest if at capacity
            if @unit_cache.size >= MAX_UNIT_CACHE && !@unit_cache.key?(cache_key)
              oldest = @unit_cache_order.shift
              @unit_cache.delete(oldest)
              @unit_cache_signatures.delete(oldest)
            end

            @unit_cache[cache_key] = data
            @unit_cache_signatures[cache_key] = signature
            @unit_cache_order.delete(cache_key)
            @unit_cache_order.push(cache_key)
          end
          data
        end
      end

      def unit_file_signature(stat)
        [stat.dev, stat.ino, stat.size, stat.mtime.to_r, stat.ctime.to_r]
      end

      def open_unit(path, &block)
        File.open(path, 'rb', &block)
      end

      # Read an index artifact as UTF-8, whatever the host locale.
      #
      # Bare Pathname#read tags the bytes with Encoding.default_external. On
      # a C/US-ASCII host that tag is US-ASCII, so a single non-ASCII byte in
      # an artifact (a branch like "feature/café" in manifest.json, a unit
      # identifier, prose in SUMMARY.md) makes JSON.parse raise
      # Encoding::InvalidByteSequenceError and leaves bare string reads with
      # an invalid encoding — search, lookup, dependencies, dependents,
      # framework, and recent_changes then surface as misleading
      # corrupt_artifact results. Reading binary (the mode {#load_unit} has
      # always used) and forcing UTF-8 keeps the bytes byte-identical while
      # giving them the encoding extraction writes artifacts in.
      #
      # @param path [Pathname] Artifact path inside the loaded generation
      # @return [String] Contents, tagged UTF-8
      def read_utf8(path)
        path.binread.force_encoding(Encoding::UTF_8)
      end

      # Parse a JSON payload file (manifest, graph, analysis) resolved through
      # the loaded generation's {#payload_dir}.
      def parse_json(filename)
        path = current_payload_dir.join(filename)
        JSON.parse(read_utf8(path))
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

          # Filter by node type if requested. An identifier naming units of
          # several types matches when any of them does — excluding it because
          # the type that happens to sort first is not the requested one would
          # hide a unit the filter asked for.
          filtered = if type_set
                       neighbors.select { |n| graph_node_types[n]&.any? { |t| type_set.include?(t) } }
                     else
                       neighbors
                     end

          # At max depth, record the node with empty deps so the renderer
          # doesn't emit an extra level of unexpanded neighbors. The parent
          # node's deps list already shows this node as a child.
          will_expand = current_depth < depth
          node_meta = nodes_data[current]
          entry = {
            type: node_meta&.dig('type'),
            depth: current_depth,
            deps: will_expand ? filtered : []
          }
          # Only when the identifier is genuinely ambiguous, so the shape is
          # unchanged for every node in an index with no shared identifiers.
          node_types = graph_node_types[current] || []
          entry[:types] = node_types if node_types.size > 1
          result_nodes[current] = entry

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
