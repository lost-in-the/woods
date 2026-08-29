# frozen_string_literal: true

require 'digest'
require 'json'
require 'logger'
require 'mcp'
require 'open3'
require 'time'
require 'set'
require 'uri'
require_relative '../atomic_file'
require_relative '../generation'
require_relative '../tasks'
require_relative '../watch/status'
require_relative '../filename_utils'
require_relative '../update_check'
require_relative 'index_reader'
require_relative 'index_reader_pinning'
require_relative 'protocol_policy'
require_relative 'tasks/extension'
require_relative 'tasks/request_capture'
require_relative 'tasks/store'
require_relative 'tool_contract'
require_relative 'tool_response_renderer'
require_relative 'version_aware_tool_dispatch'

module Woods
  module MCP
    # Builds an MCP::Server with up to 29 tools, 2 resources, and 2 resource templates
    # for querying Woods extraction output, managing pipelines, and collecting feedback.
    # 14 tools are always registered; 15 more register conditionally based on wiring:
    # 5 operator tools, 4 feedback tools, 4 snapshot tools, 1 session_trace tool,
    # 1 Notion sync tool.
    #
    # All tools are defined inline via closures over an IndexReader instance.
    # No Rails required at runtime — reads JSON files from disk.
    #
    # @example
    #   server = Woods::MCP::Server.build(index_dir: "/path/to/output")
    #   transport = MCP::Server::Transports::StdioTransport.new(server)
    #   transport.open
    #
    module Server
      # Module-level pipeline serialization state, eagerly initialized at load
      # time (self == Server here). The HTTP transport dispatches tool handlers
      # concurrently, so a lazy `@pipeline_mutex ||= Mutex.new` inside
      # pipeline_start would let two handlers each create a DIFFERENT mutex and
      # synchronize on separate locks — defeating the exclusion and allowing two
      # concurrent pipelines of the same kind.
      @pipeline_mutex = Mutex.new
      @pipeline_in_flight = {}

      # Seconds `pipeline_extract` will wait for the on-disk extraction lock
      # before reporting contention (#170). Deliberately short: the tool
      # answers a live agent, and "another writer is mid-run, retry" is a
      # better answer than a multi-minute stall (the rake writers wait
      # `LOCK_STALE_TIMEOUT` because a human started them and asked them to
      # finish). Module-level rather than inside `class << self`, so specs can
      # stub it and lexical lookup from the tool definitions still finds it.
      PIPELINE_LOCK_WAIT = 2.0

      class << self
        # Build a configured MCP::Server with all tools and resources.
        #
        # @param index_dir [String] Path to extraction output directory
        # @param retriever [Woods::Retriever, nil] Optional retriever for semantic search
        # @param operator [Hash, nil] Optional operator config with :status_reporter, :error_escalator, :pipeline_guard, :pipeline_lock
        # @param feedback_store [Woods::Feedback::Store, nil] Optional feedback store
        # @param bootstrap_state [Woods::MCP::BootstrapState, nil] Optional state
        #   from the bootstrap flow. When provided, woods_status reports the
        #   hydrated/degraded/failed lifecycle plus the reason so operators can
        #   diagnose "why is semantic search disabled" without reading the Ruby
        #   source. Nil just means the caller didn't go through Bootstrapper.
        # @param warmup [Boolean] Pre-populate the index reader's caches during build,
        #   shifting first-tool-call latency to startup. Default: true. Pass false for
        #   tests or when startup time matters more than first-query latency.
        # @return [MCP::Server] Configured server ready for transport
        def build(index_dir:, retriever: nil, operator: nil, feedback_store: nil, snapshot_store: nil,
                  bootstrap_state: nil, response_format: nil, warmup: true, retriever_reloader: nil)
          reader = IndexReader.new(index_dir)
          reader.warmup! if warmup
          config = Woods.configuration
          format = response_format || (config.respond_to?(:context_format) ? config.context_format : nil) || :markdown
          renderer = ToolResponseRenderer.for(format)
          resources = build_resources
          resource_templates = build_resource_templates

          # Lambda captured by all tool blocks for building responses.
          respond = method(:text_response)
          respond_err = method(:error_response)
          op_missing = lambda do |tool|
            error_response(
              'Pipeline operator is not configured. Pass `operator:` (a StatusReporter, ' \
              'ErrorEscalator, and PipelineGuard) to Woods::MCP::Server.build when embedding ' \
              'the server — neither packaged executable wires one today.',
              code: :not_configured, config_key: 'operator',
              doc_link: 'docs/MCP_TOOL_COOKBOOK.md#conditional-tools--wiring', tool: tool
            )
          end
          fb_missing = lambda do |tool|
            error_response(
              'Feedback store is not configured. Pass `feedback_store:` to Woods::MCP::Server.build ' \
              'to enable retrieval feedback capture.',
              code: :not_configured, config_key: 'feedback_store',
              doc_link: 'docs/MCP_TOOL_COOKBOOK.md#conditional-tools--wiring', tool: tool
            )
          end
          snap_missing = lambda do |tool|
            error_response(
              'Snapshot store is not configured. Set `enable_snapshots: true` in Woods.configure ' \
              'and pass `snapshot_store:` to Woods::MCP::Server.build.',
              code: :not_configured, config_key: 'enable_snapshots',
              doc_link: 'docs/MCP_TOOL_COOKBOOK.md#conditional-tools--wiring', tool: tool
            )
          end

          server = ::MCP::Server.new(
            name: 'woods',
            version: Woods::VERSION,
            resources: resources,
            resource_templates: resource_templates,
            configuration: ::MCP::Configuration.new.merge(::MCP.configuration),
            **ProtocolPolicy.cache_hints
          )
          # Rewrite "Tool not found" into version-aware update guidance for agents
          # running against an older gem than the skill they're following assumes.
          server.singleton_class.prepend(VersionAwareToolDispatch)
          # Make the per-request Tasks opt-in reachable from a tool handler,
          # which otherwise only sees `arguments`.
          server.singleton_class.prepend(Tasks::RequestCapture)

          # The Tasks extension backs the two long-running tools. Registered
          # unconditionally rather than only alongside `operator`, because
          # `tasks/get` must keep answering for a handle minted by a *previous*
          # process — the crash-resilience case is precisely the one where this
          # server was restarted and may come up wired differently.
          task_store = Tasks::Store.new(index_dir)
          Tasks::Extension.install(server, store: task_store)

          define_lookup_tool(server, reader, respond, respond_err, renderer)
          define_search_tool(server, reader, respond, respond_err, renderer)
          define_traversal_tool(server, reader, respond, renderer,
                                name: 'dependencies',
                                description: 'Traverse forward dependencies of a unit (what it depends on). Returns a BFS tree with depth.',
                                reader_method: :traverse_dependencies,
                                render_key: :dependencies)
          define_traversal_tool(server, reader, respond, renderer,
                                name: 'dependents',
                                description: 'Traverse reverse dependencies of a unit (what depends on it). Returns a BFS tree with depth.',
                                reader_method: :traverse_dependents,
                                render_key: :dependents)
          define_structure_tool(server, reader, respond, renderer)
          define_graph_analysis_tool(server, reader, respond, renderer)
          define_domain_clusters_tool(server, reader, respond, renderer)
          define_pagerank_tool(server, reader, respond, renderer)
          define_framework_tool(server, reader, respond, renderer)
          define_recent_changes_tool(server, reader, respond, renderer)
          define_reload_tool(server, reader, respond, retriever_reloader)
          define_retrieve_tool(server, retriever, respond, respond_err, bootstrap_state)
          define_trace_flow_tool(server, reader, respond, respond_err, renderer)
          # Conditionally register collaborator-dependent tools. Historically
          # all 15 stubs were registered unconditionally and returned
          # isError: true when the wiring was missing — that added token
          # noise to every LLM turn's tool catalog and invited the model to
          # try tools guaranteed to fail. Only register when the collaborator
          # is wired, so tools/list reflects what the server can actually do.
          define_session_trace_tool(server, reader, respond, respond_err) if session_tracer_wired?
          define_operator_tools(server, operator, respond, respond_err, op_missing, task_store) if operator
          define_feedback_tools(server, feedback_store, respond, respond_err, fb_missing) if feedback_store
          define_snapshot_tools(server, snapshot_store, respond, respond_err, snap_missing) if snapshot_store
          define_notion_sync_tool(server, reader, index_dir, respond, respond_err) if notion_wired?
          define_woods_status_tool(server, reader, retriever, index_dir, bootstrap_state, respond)
          register_resource_handler(server, reader)
          ToolContract.apply!(server)
          IndexReaderPinning.install(server, reader: reader)

          # Last, after every conditional registration above — the whole point is
          # that a host with Notion wired advertises the same tool order as one
          # without it.
          ProtocolPolicy.sort_tools!(server)
        end

        private

        # Session tracer requires a configured session_store on Woods.configuration.
        # The tool reads the store inside its handler; skipping registration when
        # the store is absent keeps tools/list honest.
        #
        # The `session_trace` handler itself only calls `store.read`. We
        # ALSO probe `:sessions` as a defense-in-depth cheap contract
        # check — every shipped store (File/Redis/SolidCache) implements
        # both, so if a misconfigured store lacks `:sessions` it is almost
        # certainly missing `:read` too, and we'd rather fail at wire-up
        # than at first invocation. A record-only store (permitted by the
        # middleware for backward-compatibility) will correctly drop out
        # of tools/list here.
        def session_tracer_wired?
          config = Woods.configuration
          return false unless config
          return false unless config.respond_to?(:session_store)

          store = config.session_store
          return false if store.nil?

          %i[read sessions].all? { |m| store.respond_to?(m) }
        end

        # Notion export needs both an API token and at least one database ID.
        # A non-blank NOTION_API_TOKEN env var overrides the config token (see
        # docs/NOTION_INTEGRATION.md). Resolution goes through
        # Woods.resolve_notion_token so a blank env var is treated as absent
        # (rather than masking a valid configured token) — matching the
        # exporter and the notion_sync handler.
        def notion_wired?
          config = Woods.configuration
          return false unless config

          token = Woods.resolve_notion_token(config)
          ids = config.respond_to?(:notion_database_ids) ? config.notion_database_ids : nil
          !token.nil? && ids && !ids.empty?
        end

        def text_response(text)
          structured = { text: text }
          structured[:data] = JSON.parse(text)
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: text }],
            structured_content: structured
          )
        rescue JSON::ParserError
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: text }],
            structured_content: structured
          )
        end

        # Build a structured error response that carries machine-readable
        # metadata alongside the human-readable text. Agents can branch on
        # `_meta.error_code` (e.g. `:not_configured`, `:not_found`,
        # `:rate_limited`, `:unsupported_argument`) without parsing the text.
        #
        # @param message [String] Human-readable explanation
        # @param code [Symbol] Stable error code (machine-readable)
        # @param config_key [String, nil] Offending configuration key when relevant
        # @param doc_link [String, nil] Relative docs path explaining the fix
        # @param extra [Hash] Additional meta fields (e.g., identifier:, tool:)
        def error_response(message, code:, config_key: nil, doc_link: nil, **extra)
          meta = { error_code: code }
          meta[:config_key] = config_key if config_key
          meta[:doc_link] = doc_link if doc_link
          meta.merge!(extra) unless extra.empty?
          ::MCP::Tool::Response.new(
            [{ type: 'text', text: message }],
            error: true,
            structured_content: { text: message },
            meta: meta
          )
        end

        def truncate_section(array, limit)
          return array unless array.is_a?(Array)

          limit = [limit, 0].max
          array.first(limit).map do |item|
            next item unless item.is_a?(Hash) && item['dependents'].is_a?(Array) && item['dependents'].size > limit

            item.merge(
              'dependents' => item['dependents'].first(limit),
              'dependents_truncated' => true,
              'dependents_total' => item['dependents'].size
            )
          end
        end

        # Coerce a value to an Array. Wraps a single String in an Array;
        # leaves existing Arrays and nil unchanged.
        #
        # @param value [String, Array, nil] The input value
        # @return [Array, nil]
        def coerce_array(value)
          value.is_a?(String) ? [value] : value
        end

        # Coerce a value to an Integer.
        #
        # - `nil` passes through unchanged.
        # - `Integer` passes through unchanged.
        # - `String` is accepted iff it represents a decimal integer with an
        #   optional leading `+`/`-`. `"abc"` and `"1abc"` used to silently
        #   coerce to `0` via `String#to_i`; that was a footgun for tools with
        #   integer bounds (limit, offset, budget, timeout) — they'd receive
        #   the wrong value without any feedback to the client. Now we raise
        #   `ArgumentError` so the MCP dispatch layer can surface a proper
        #   JSON-RPC error back to the caller.
        # - Any other type raises `ArgumentError`.
        #
        # @param value [String, Integer, nil]
        # @return [Integer, nil]
        # @raise [ArgumentError] if `value` is not nil, Integer, or an Integer-shaped String.
        INTEGER_STRING = /\A[+-]?\d+\z/
        private_constant :INTEGER_STRING
        def coerce_integer(value)
          return nil if value.nil?
          return value if value.is_a?(Integer)

          return Integer(value, 10) if value.is_a?(String) && value.match?(INTEGER_STRING)

          raise ArgumentError, "expected integer, got #{value.class}: #{value.inspect}"
        end

        # Load a precomputed flow document written by FlowPrecomputer, when
        # `config.precompute_flows` was enabled during extraction. Returns nil
        # when the entry point is missing a method suffix, the JSON file isn't
        # on disk, or the file can't be read or parsed — callers fall back to
        # FlowAssembler.
        #
        # @param index_dir [String]
        # @param entry_point [String] e.g., "PostsController#create"
        # @return [Woods::FlowDocument, nil]
        def load_precomputed_flow(index_dir, entry_point)
          return nil unless entry_point.to_s.include?('#')

          controller, action = entry_point.split('#', 2)
          return nil if controller.empty? || action.empty?

          # entry_point is client input — FilenameUtils.flow_filename
          # allow-lists both parts (so `/` and `..` can't traverse outside
          # flows/) using the SAME transform FlowPrecomputer writes with, so a
          # legitimately precomputed flow always resolves to the file on disk.
          filename = Woods::FilenameUtils.flow_filename(controller, action)
          # The path is derived from the entry point and joined against THIS
          # process's index_dir — the path *values* in flow_index.json /
          # metadata[:flow_paths] are never consulted. That is what keeps
          # both formats working unchanged: post-#190 indexes persist
          # output_dir-relative values ("flows/X_y.json"), while pre-#190
          # indexes persisted the extraction machine's absolute paths (e.g.
          # container-side "/app/tmp/woods/flows/X_y.json"), which need not
          # resolve on the reading host at all.
          path = File.join(index_dir, 'flows', filename)
          return nil unless File.exist?(path)

          # AtomicFile.read, not File.read: flow documents carry free-text
          # (args_hint / condition strings) that can be non-ASCII, and a bare
          # read under LANG=C tags the result US-ASCII so the first
          # JSON.parse raises Encoding::InvalidByteSequenceError.
          Woods::FlowDocument.from_h(JSON.parse(Woods::AtomicFile.read(path)))
        rescue JSON::ParserError, Errno::ENOENT, EncodingError
          # EncodingError included so ANY unreadable precomputed flow (torn,
          # corrupt, mis-encoded bytes) degrades to query-time reassembly as
          # documented, instead of escaping to trace_flow's generic handler
          # as an internal_error.
          nil
        end

        # Apply offset+limit pagination to a single section key within a container hash.
        # Adds `_total`, `_truncated`, and `_offset` metadata keys when truncating.
        #
        # @param container [Hash] The hash to mutate
        # @param key [String] The section key whose value is an Array
        # @param limit [Integer, nil] Max items to retain; nil means no limit
        # @param offset [Integer] Items to skip from the front
        # @return [void]
        def paginate_section(container, key, limit, offset)
          original = container[key]
          return unless original.is_a?(Array)

          sliced = offset.positive? ? original.drop(offset) : original
          container[key] = limit ? truncate_section(sliced, limit) : sliced
          if original.size > offset + (limit || original.size)
            container["#{key}_total"] = original.size
            container["#{key}_truncated"] = true
          end
          container["#{key}_offset"] = offset if offset.positive?
        end

        def define_lookup_tool(server, reader, respond, respond_err, renderer)
          coerce = method(:coerce_array)
          server.define_tool(
            name: 'lookup',
            description: 'Look up a code unit by its exact identifier. Returns full source code, metadata, ' \
                         'dependencies, and dependents. Use include_source: false to omit source_code. ' \
                         'Use sections to select specific keys (type, identifier, file_path, namespace are always included). ' \
                         '`name` is accepted as an alias for `identifier` for discoverability.',
            input_schema: {
              properties: {
                identifier: { type: 'string',
                              description: 'Exact unit identifier (e.g. "Post", "PostsController", "Api::V1::HealthController")' },
                name: { type: 'string', description: 'Alias for `identifier`. Either one works.' },
                include_source: { type: 'boolean', description: 'Include source_code in response (default: true)' },
                sections: {
                  type: 'array', items: { type: 'string' },
                  description: 'Select specific keys to return (e.g. ["metadata", "dependencies"]). Always includes type, identifier, file_path, namespace.'
                }
              }
              # NOTE: 'identifier' is not listed as required — `name` is an
              # accepted alias. The handler validates that one of the two
              # was provided.
            }
          ) do |server_context:, identifier: nil, name: nil, include_source: nil, sections: nil|
            identifier ||= name
            if identifier.nil? || identifier.empty?
              next respond_err.call(
                'lookup requires `identifier` (or its alias `name`).',
                code: :unsupported_argument,
                tool: 'lookup',
                argument: 'identifier',
                hint: 'Pass identifier: "PostsController" (or name: "PostsController").'
              )
            end
            sections = coerce.call(sections)
            unit = reader.find_unit(identifier)
            if unit
              always_include = %w[type identifier file_path namespace]
              filtered = unit
              filtered = filtered.except('source_code') if include_source == false
              if sections&.any?
                allowed = (always_include + sections).to_set
                filtered = filtered.slice(*allowed)
              end
              respond.call(renderer.render(:lookup, filtered))
            else
              respond_err.call(
                "Unit not found: #{identifier}",
                code: :not_found,
                identifier: identifier,
                tool: 'lookup',
                hint: 'Use `search` to find identifiers by pattern, then `lookup` on the exact match.'
              )
            end
          end
        end

        def define_search_tool(server, reader, respond, respond_err, renderer)
          coerce = method(:coerce_array)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'search',
            description: 'Find code units whose identifiers (or source/metadata) match a regex. ' \
                         'Example: search("Worker|Job") returns all workers and jobs; search("^Post") ' \
                         'returns units starting with "Post". Returns [{identifier, type, match_field}]. ' \
                         'Use `lookup` for exact identifiers, `dependencies`/`dependents` for graph traversal. ' \
                         'Gotchas: query is a Ruby regex — literal pipe needs escaping as \\|; ' \
                         'types restricts which index directories are scanned (e.g. ["mailer"] scans only ' \
                         'the mailers dir); invalid regex falls back to literal match. ' \
                         'For plain prefix/suffix matching on namespaces, prefer exact_prefix / exact_suffix ' \
                         '(literal, case-insensitive) over escaping regex anchors.',
            input_schema: {
              properties: {
                query: { type: 'string', description: 'Case-insensitive Ruby regex pattern (e.g. "Worker|Job", "^Post", ".*Service$")' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Restrict scan to these unit types: model, controller, service, job, mailer, etc.'
                },
                fields: {
                  type: 'array', items: { type: 'string' },
                  description: 'Fields to search: identifier (default), source_code, metadata'
                },
                limit: { type: 'integer', description: 'Maximum results (default: 20)' },
                exact_prefix: {
                  type: 'string',
                  description: 'Literal (non-regex) case-insensitive identifier prefix filter. ' \
                               'Use for namespace scoping like "Next::Settings::" without escaping regex metacharacters.'
                },
                exact_suffix: {
                  type: 'string',
                  description: 'Literal (non-regex) case-insensitive identifier suffix filter. ' \
                               'Use for suffix matching like "Controller" without escaping regex metacharacters.'
                }
              }
            }
          ) do |server_context:, query: nil, types: nil, fields: nil, limit: nil, exact_prefix: nil, exact_suffix: nil|
            if (query.nil? || query.empty?) &&
               (exact_prefix.nil? || exact_prefix.empty?) &&
               (exact_suffix.nil? || exact_suffix.empty?)
              next respond_err.call(
                'search requires `query` or at least one of `exact_prefix` / `exact_suffix`.',
                code: :unsupported_argument,
                tool: 'search',
                argument: 'query',
                hint: 'Pass query: "Worker|Job" for regex matching, or exact_prefix: "Next::Settings::" for literal prefix scoping.'
              )
            end
            types = coerce.call(types)
            fields = coerce.call(fields)
            limit = coerce_int.call(limit)
            search_result = reader.search(
              query,
              types: types,
              fields: fields || %w[identifier],
              limit: limit || 20,
              exact_prefix: exact_prefix,
              exact_suffix: exact_suffix
            )
            results = search_result[:results]
            payload = {
              query: query,
              result_count: results.size,
              results: results
            }
            payload[:note] = search_result[:note] if search_result[:note]
            payload[:partial] = true if search_result[:partial]
            respond.call(renderer.render(:search, payload))
          end
        end

        def define_traversal_tool(server, reader, respond, renderer, name:, description:, reader_method:, render_key:)
          coerce = method(:coerce_array)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: name,
            description: description,
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier to start from' },
                depth: { type: 'integer', description: 'Maximum traversal depth (default: 2)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                },
                via: {
                  anyOf: [
                    { type: 'string' },
                    { type: 'array', items: { type: 'string' } }
                  ],
                  description: 'Filter by relationship type. Accepts either a single string ' \
                               "(e.g. 'code_reference') or an array " \
                               "(e.g. ['code_reference','render']); both forms are coerced to an array internally. " \
                               'Known values: link_to, redirect_to, form_action, render, code_reference, ' \
                               'belongs_to, has_many, has_one, has_and_belongs_to_many, polymorphic_interface.'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:, depth: nil, types: nil, via: nil|
            types = coerce.call(types)
            via = coerce.call(via)
            depth = coerce_int.call(depth)
            result = reader.send(reader_method, identifier, depth: depth || 2, types: types, via: via)
            if result[:found] == false
              result[:message] =
                "Identifier '#{identifier}' not found in the index. Use 'search' to find valid identifiers."
            end
            respond.call(renderer.render(render_key, result))
          end
        end

        def define_structure_tool(server, reader, respond, renderer)
          server.define_tool(
            name: 'structure',
            description: 'Get codebase structure overview. Returns manifest (counts, versions, git info) and optionally the full summary.',
            input_schema: {
              properties: {
                detail: {
                  type: 'string', enum: %w[summary full],
                  description: '"summary" for manifest only, "full" to include SUMMARY.md. Default: summary'
                }
              }
            }
          ) do |server_context:, detail: nil|
            result = { manifest: reader.manifest, template_engines: reader.template_engines }
            result[:summary] = reader.summary if (detail || 'summary') == 'full'
            respond.call(renderer.render(:structure, result))
          end
        end

        def define_graph_analysis_tool(server, reader, respond, renderer)
          paginate = method(:paginate_section)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'graph_analysis',
            description: 'Get structural analysis of the dependency graph: orphans, dead ends, hubs, cycles, and bridges.',
            input_schema: {
              properties: {
                analysis: {
                  type: 'string',
                  enum: %w[orphans dead_ends hubs cycles bridges all],
                  description: 'Which analysis to return. Default: all'
                },
                limit: { type: 'integer', description: 'Limit results per section (default: 20)' },
                offset: { type: 'integer', description: 'Skip this many results per section (default: 0)' }
              }
            }
          ) do |server_context:, analysis: nil, limit: nil, offset: nil|
            limit = coerce_int.call(limit)
            offset = coerce_int.call(offset)
            data = reader.graph_analysis
            section = analysis || 'all'
            effective_offset = offset || 0

            result = if section == 'all'
                       if limit || effective_offset.positive?
                         truncated = data.dup
                         %w[orphans dead_ends hubs cycles bridges].each do |key|
                           paginate.call(truncated, key, limit, effective_offset)
                         end
                         truncated
                       else
                         data
                       end
                     else
                       single = { section => data[section], 'stats' => data['stats'] }
                       paginate.call(single, section, limit, effective_offset) if limit || effective_offset.positive?
                       single
                     end

            respond.call(renderer.render(:graph_analysis, result))
          end
        end

        def define_domain_clusters_tool(server, reader, respond, renderer)
          coerce = method(:coerce_array)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'domain_clusters',
            description: 'Group code units into semantic domains by namespace and graph connectivity. ' \
                         'Returns clusters with hub nodes, entry points, boundary edges, and type breakdowns. ' \
                         'Useful for understanding architectural domains and blast radius.',
            input_schema: {
              properties: {
                min_size: {
                  type: 'integer',
                  description: 'Minimum units per cluster before merging into neighbors (default: 3)'
                },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these unit types (default: all). Example: ["model", "service", "job"]'
                }
              }
            }
          ) do |server_context:, min_size: nil, types: nil|
            min_size = coerce_int.call(min_size) || 3
            types = coerce.call(types)

            graph = reader.dependency_graph
            analyzer = Woods::GraphAnalyzer.new(graph)

            clusters = analyzer.domain_clusters(min_size: min_size, types: types)

            respond.call(renderer.render(:domain_clusters, { clusters: clusters, total: clusters.size }))
          end
        end

        def define_pagerank_tool(server, reader, respond, renderer)
          coerce = method(:coerce_array)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'pagerank',
            description: 'Get PageRank importance scores for code units. Higher scores indicate more structurally important nodes.',
            input_schema: {
              properties: {
                limit: { type: 'integer', description: 'Maximum results to return (default: 20)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              }
            }
          ) do |server_context:, limit: nil, types: nil|
            types = coerce.call(types)
            limit = coerce_int.call(limit)
            scores = reader.dependency_graph.pagerank
            graph_data = reader.raw_graph_data
            nodes = graph_data['nodes'] || {}

            type_set = types&.to_set

            ranked = scores
                     .sort_by { |_id, score| -score }
                     .filter_map do |id, score|
                       node_type = nodes.dig(id, 'type')
                       next if type_set && !type_set.include?(node_type)

                       { identifier: id, type: node_type, score: score.round(6) }
                     end

            effective_limit = limit || 20
            result = {
              total_nodes: scores.size,
              results: ranked.first(effective_limit)
            }
            respond.call(renderer.render(:pagerank, result))
          end
        end

        def define_framework_tool(server, reader, respond, renderer)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'framework',
            description: 'Search Rails framework source units by concept keyword. Matches against identifier, ' \
                         'source_code, and metadata of rails_source type units extracted from installed gems.',
            input_schema: {
              properties: {
                keyword: { type: 'string',
                           description: 'Concept keyword to search for (e.g. "ActiveRecord", "routing", "callbacks")' },
                limit: { type: 'integer', description: 'Maximum results (default: 20)' }
              },
              required: ['keyword']
            }
          ) do |keyword:, server_context:, limit: nil|
            limit = coerce_int.call(limit)
            results = reader.framework_sources(keyword, limit: limit || 20)
            respond.call(renderer.render(:framework, {
                                           keyword: keyword,
                                           result_count: results.size,
                                           results: results
                                         }))
          end
        end

        def define_recent_changes_tool(server, reader, respond, renderer)
          coerce = method(:coerce_array)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'recent_changes',
            description: 'List recently modified code units sorted by git last_modified timestamp. ' \
                         'Returns the most recently changed units first.',
            input_schema: {
              properties: {
                limit: { type: 'integer', description: 'Maximum results (default: 10)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types: model, controller, service, job, mailer, etc.'
                }
              }
            }
          ) do |server_context:, limit: nil, types: nil|
            types = coerce.call(types)
            limit = coerce_int.call(limit)
            results = reader.recent_changes(limit: limit || 10, types: types)
            respond.call(renderer.render(:recent_changes, {
                                           result_count: results.size,
                                           results: results
                                         }))
          end
        end

        def define_reload_tool(server, reader, respond, retriever_reloader)
          server.define_tool(
            name: 'reload',
            description: 'Reload extraction data from disk. Use after re-running extraction or woods:embed to pick ' \
                         'up changes without restarting the server. Refreshes the JSON index (manifest, dependency ' \
                         'graph, unit cache) AND re-hydrates the retriever\'s in-memory vector/metadata/graph ' \
                         'stores from the latest dumps. Durable backends (pgvector, Qdrant) are auto-refreshed ' \
                         'externally — their counts in the response reflect the read-through state.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            reader.with_exclusive_reload do |manifest|
              payload = {
                reloaded: true,
                extracted_at: manifest['extracted_at'],
                total_units: manifest['total_units'],
                counts: manifest['counts']
              }
              if retriever_reloader
                begin
                  payload[:retriever] = retriever_reloader.call
                rescue StandardError => e
                  payload[:retriever] = { error: "#{e.class}: #{e.message}" }
                end
              end
              respond.call(JSON.pretty_generate(payload))
            end
          end
        end

        def define_retrieve_tool(server, retriever, respond, respond_err, bootstrap_state = nil)
          coerce_int = method(:coerce_integer)
          coerce = method(:coerce_array)
          stale_check = method(:stale_index_result?)
          degraded_response = method(:degraded_retrieval_response)
          server.define_tool(
            name: 'codebase_retrieve',
            description: 'Semantic search: retrieve relevant code units for a natural-language question. ' \
                         'Example: codebase_retrieve("how does billing work?") returns ranked source context. ' \
                         'Returns a token-budgeted context string ready to paste into a prompt. ' \
                         'Use `search` for exact name/pattern matching; use this for conceptual questions. ' \
                         'Requires an embedding provider — disabled if OPENAI_API_KEY is unset and Ollama is unreachable. ' \
                         'By default excludes test_mappings (~33% of a typical index) so spec filenames do not ' \
                         'dominate semantic rank; pass types: ["test_mapping"] to opt back in. ' \
                         'Parameter: use `budget` for the token budget (not `limit` — that means result count ' \
                         'on sibling tools, and mapping it here would silently produce a near-empty response).',
            input_schema: {
              properties: {
                query: { type: 'string',
                         description: 'Natural language question (e.g. "How does user authentication work?")' },
                budget: { type: 'integer',
                          description: 'Token budget for context assembly (default: 8000).' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Restrict results to these unit types (model, controller, service, job, mailer, ' \
                               'rails_source, test_mapping, etc.). Overrides the default test_mapping exclusion. ' \
                               'When the unfiltered top-K has no candidate of a requested type, the retriever ' \
                               'falls back to rank-within-type so the response is populated whenever units of ' \
                               'the requested type exist in the index. The response appends a "Type rank ' \
                               'context" table with per-type: source, rank in unfiltered top-K, global_k, ' \
                               'total_of_type. Read source to tell the cases apart: in_top_k (strong match), ' \
                               'within_type_fallback (weak match surfaced by the fallback), outside_top_k ' \
                               '(index has this type but other requested types filled the result), absent ' \
                               '(zero units of this type in the index).'
                },
                exclude_types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Additional types to exclude on top of the default test_mapping exclusion.'
                }
              },
              required: ['query']
            }
          ) do |query:, server_context:, budget: nil, limit: nil, types: nil, exclude_types: nil|
            # `limit` isn't declared in the schema but clients still send it
            # because sibling tools (search, recent_changes, pagerank) use
            # `limit` as a result count. Mapping it to `budget` here would
            # silently produce a near-empty response (limit: 10 → 10-token
            # budget). Surface a helpful typed error instead.
            unless limit.nil?
              next respond_err.call(
                'codebase_retrieve uses `budget` (token budget, default 8000), not `limit`. ' \
                '`limit` is the result-count parameter on sibling tools (search, recent_changes, pagerank). ' \
                "Pass `budget: #{coerce_int.call(limit)}` if you meant a #{coerce_int.call(limit)}-token context, " \
                'or drop the kwarg entirely for the default 8000.',
                code: :unsupported_argument,
                tool: 'codebase_retrieve',
                argument: 'limit',
                hint: 'Use `budget:` for tokens. Retrieval does not cap by result count — the token budget ' \
                      'governs how many ranked units fit in the returned context.'
              )
            end

            budget = coerce_int.call(budget)
            types = coerce.call(types)
            exclude_types = coerce.call(exclude_types)
            # M6: a hydration failure at boot left the in-memory stores
            # empty. Every query would come back as a clean empty result —
            # indistinguishable from "no matches" — so surface the degraded
            # state as typed metadata instead of answering with nothing.
            if bootstrap_state&.hydration_failed?
              failures = bootstrap_state.hydration_failures
              next degraded_response.call(
                respond_err,
                reason: failures.values.map { |e| "#{e.class}: #{e.message}" }.join('; '),
                stores: failures.keys.map(&:to_s),
                phase: 'boot'
              )
            end
            if retriever
              result = retriever.retrieve(
                query,
                budget: budget || 8000,
                types: types,
                exclude_types: exclude_types
              )
              if stale_check.call(result)
                next respond_err.call(
                  'The vector index appears stale: matches were found but their source data is ' \
                  'missing (likely a deleted or renamed unit). Re-run `woods:embed` (or ' \
                  '`woods:embed_incremental`) to refresh the index, then retry.',
                  code: :stale_index,
                  tool: 'codebase_retrieve'
                )
              end
              respond.call(result.context)
            else
              respond_err.call(
                'Semantic search is disabled — no embedding provider is configured. ' \
                'To enable: set OPENAI_API_KEY, or run Ollama locally ' \
                '(brew install ollama && ollama serve && ollama pull nomic-embed-text). ' \
                'Use the `search` tool for pattern-based matching in the meantime.',
                code: :not_configured,
                config_key: 'embedding_provider',
                doc_link: 'docs/RETRIEVAL_GUIDE.md#configuring-retrieval',
                tool: 'codebase_retrieve'
              )
            end
          end
        end

        # Detect a stale vector index: candidates matched the query but every
        # one of them pointed at a unit the metadata store no longer has
        # (deleted/renamed since the last embed). Distinguishes that case
        # from a genuine "no matches" so the tool can say what happened
        # instead of returning near-empty context as clean success.
        #
        # @param result [Woods::Retriever::RetrievalResult] (or a test double
        #   with the same shape — +trace+ may be absent/nil on older doubles)
        # @return [Boolean]
        def stale_index_result?(result)
          trace = result.respond_to?(:trace) ? result.trace : nil
          return false unless trace

          trace.ranked_count.to_i.positive? &&
            trace.skipped_missing_metadata.to_i.positive? &&
            Array(result.sources).empty?
        end

        # Typed degraded-metadata response for codebase_retrieve (M6/M8). A
        # degraded retriever must never answer with a clean empty result: the
        # response is a tool error carrying the machine-readable degraded
        # marker, which stores are affected, and the underlying reason.
        #
        # @param respond_err [Method] the tool error-response builder
        # @param reason [String] human-readable failure summary
        # @param stores [Array<String>] affected store component names
        # @param phase [String] 'boot' (hydration failure) or 'query'
        #   (store failure at query time)
        # @return [MCP::Tool::Response]
        def degraded_retrieval_response(respond_err, reason:, stores:, phase:)
          respond_err.call(
            "Semantic search is degraded: #{reason}. The affected store(s) return no data, so " \
            'queries would come back empty — this is NOT "no results". ' \
            'Run `woods_status` for the bootstrap report, re-run `woods:embed` if the index is stale, ' \
            'and restart the server once the store is loadable.',
            code: :degraded_index,
            tool: 'codebase_retrieve',
            degraded: true,
            phase: phase,
            stores: stores,
            reason: reason
          )
        end

        def define_trace_flow_tool(server, reader, respond, respond_err, renderer)
          require_relative '../flow_assembler'
          require_relative '../flow_document'
          require_relative '../dependency_graph'
          coerce_int = method(:coerce_integer)
          load_precomputed = method(:load_precomputed_flow)

          server.define_tool(
            name: 'trace_flow',
            description: 'Trace execution flow from an entry point through the codebase',
            input_schema: {
              properties: {
                entry_point: {
                  type: 'string',
                  description: 'Entry point (e.g., UsersController#create)'
                },
                depth: {
                  type: 'integer',
                  description: 'Maximum call depth to trace (default: 3)'
                }
              },
              required: ['entry_point']
            }
          ) do |entry_point:, server_context:, depth: nil|
            max_depth = coerce_int.call(depth) || 3

            # Prefer the precomputed flow JSON written by FlowPrecomputer during
            # extraction (gated on `config.precompute_flows`) — it avoids
            # re-parsing source on every request. Fall back to query-time
            # reassembly when no precomputed document exists.
            flow_doc = load_precomputed.call(reader.payload_dir, entry_point)
            flow_doc ||= begin
              graph = reader.dependency_graph
              assembler = Woods::FlowAssembler.new(graph: graph, extracted_dir: reader.payload_dir.to_s)
              assembler.assemble(entry_point, max_depth: max_depth)
            end

            respond.call(renderer.render(:trace_flow, flow_doc.to_h))
          rescue StandardError => e
            # Emit an MCP error so clients can detect the failure and
            # surface it, rather than wrapping the error payload in a
            # successful response — consistent with session_trace and
            # codebase_retrieve.
            if ToolContract.artifact_error?(e)
              next respond_err.call(
                'trace_flow could not read a required Index artifact.',
                code: :corrupt_artifact,
                tool: 'trace_flow'
              )
            end

            respond_err.call(
              "trace_flow failed: #{e.message}",
              code: :internal_error,
              data: { entry_point: entry_point, exception: e.class.name }
            )
          end
        end

        def define_session_trace_tool(server, reader, respond, respond_err)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'session_trace',
            description: 'Assemble context from a browser session trace (requires session tracer middleware)',
            input_schema: {
              properties: {
                session_id: { type: 'string', description: 'Session ID to trace' },
                budget: { type: 'integer', description: 'Max token budget (default: 8000)' },
                depth: { type: 'integer', description: 'Dependency resolution depth (default: 1)' }
              },
              required: ['session_id']
            }
          ) do |session_id:, server_context:, budget: nil, depth: nil|
            budget = coerce_int.call(budget)
            depth = coerce_int.call(depth)
            store = Woods.configuration.session_store
            unless store
              next respond_err.call(
                'Session tracer is not configured. Assign `session_store` (FileStore, RedisStore, or SolidCacheStore) ' \
                'and set `session_tracer_enabled = true` in Woods.configure.',
                code: :not_configured,
                config_key: 'session_store',
                doc_link: 'docs/MCP_TOOL_COOKBOOK.md#conditional-tools--wiring',
                tool: 'session_trace'
              )
            end

            require_relative '../session_tracer/session_flow_assembler'

            assembler = Woods::SessionTracer::SessionFlowAssembler.new(
              store: store, reader: reader
            )
            doc = assembler.assemble(session_id, budget: budget || 8000, depth: depth || 1)
            respond.call(doc.to_markdown)
          rescue StandardError => e
            respond_err.call(
              "Session trace failed: #{e.message}",
              code: :internal_error,
              tool: 'session_trace',
              session_id: session_id
            )
          end
        end

        def define_operator_tools(server, operator, respond, respond_err, op_missing, task_store)
          define_pipeline_extract_tool(server, operator, respond, respond_err, op_missing, task_store)
          define_pipeline_embed_tool(server, operator, respond, respond_err, op_missing, task_store)
          define_pipeline_status_tool(server, operator, respond, respond_err, op_missing)
          define_pipeline_diagnose_tool(server, operator, respond, respond_err, op_missing)
          define_pipeline_repair_tool(server, operator, respond, respond_err, op_missing)
        end

        def define_feedback_tools(server, feedback_store, respond, _respond_err, fb_missing)
          define_retrieval_rate_tool(server, feedback_store, respond, fb_missing)
          define_retrieval_report_gap_tool(server, feedback_store, respond, fb_missing)
          define_retrieval_explain_tool(server, feedback_store, respond, fb_missing)
          define_retrieval_suggest_tool(server, feedback_store, respond, fb_missing)
        end

        def define_pipeline_extract_tool(server, operator, respond, respond_err, op_missing, task_store)
          cooldown = method(:cooldown_error)
          server.define_tool(
            name: 'pipeline_extract',
            description: 'Trigger a codebase extraction pipeline run. Checks rate limits before proceeding.',
            input_schema: {
              properties: {
                incremental: { type: 'boolean', description: 'Run incremental extraction (default: false)' },
                changed_files: {
                  type: 'array',
                  items: { type: 'string' },
                  description: 'Required when incremental is true: repo-relative paths of changed files ' \
                               '(the MCP server has no git context to compute them itself).'
                }
              }
            }
          ) do |server_context:, incremental: nil, changed_files: nil|
            next op_missing.call('pipeline_extract') unless operator

            # Incremental extraction re-extracts only the units affected by
            # the given files. The MCP server has no git-diff context (unlike
            # the rake task, which derives them from CHANGED_FILES / CI env),
            # so an empty list would re-extract nothing while still bumping
            # the manifest timestamp — a silent no-op reporting success.
            # Require the caller to supply the changed files explicitly.
            files = Array(changed_files).map(&:to_s).reject(&:empty?)
            if incremental && files.empty?
              next respond_err.call(
                'Incremental extraction requires a non-empty changed_files list. ' \
                'Pass the changed paths, or run `rake woods:incremental` which derives them from git.',
                code: :invalid_params,
                tool: 'pipeline_extract'
              )
            end

            guard = operator[:pipeline_guard]
            if (blocked = cooldown.call(guard, :extraction, 'pipeline_extract'))
              next blocked
            end

            # Acquire the in-process lock BEFORE recording to the guard.
            # Otherwise a refused "already running" request still resets
            # the cooldown clock and blocks the next legitimate attempt
            # for the full 5-minute window once the current run finishes.
            unless Woods::MCP::Server.send(:pipeline_start, :extraction)
              next respond_err.call(
                'Extraction pipeline is already running. Wait for it to complete.',
                code: :already_running,
                tool: 'pipeline_extract'
              )
            end

            # Cross-PROCESS serialization (#170). pipeline_start only guards
            # this process; the rake writers and the watch daemon serialize on
            # the on-disk PipelineLock, and an unlocked MCP extraction was the
            # sixth writer — free to rewrite the dependency graph under any of
            # them, with the loser's work silently discarded. The wait is
            # short and the failure explicit: an MCP tool must not sit on a
            # lock queue for minutes the way `woods:extract` does, so
            # contention becomes a clear tool error the caller can retry.
            #
            # A nil/duck-typed configuration (no output_dir) yields no lock —
            # there is no known lock domain, and the extraction below fails in
            # the background exactly as it always has on an unconfigured host.
            config = Woods.configuration
            output_dir = config.output_dir if config.respond_to?(:output_dir)
            lock = output_dir && Woods::MCP::Server.send(:build_extraction_lock, output_dir)
            if lock && !Woods::MCP::Server.send(:acquire_lock_briefly, lock)
              Woods::MCP::Server.send(:pipeline_finish, :extraction)
              next respond_err.call(
                'Another writer holds the extraction lock (a rake task or the watch daemon ' \
                'is writing this index). Try again shortly.',
                code: :locked,
                tool: 'pipeline_extract'
              )
            end

            run_extraction = lambda do
              # exe/woods-mcp deliberately loads no extraction machinery, so
              # Woods::Extractor is not defined in a standalone index-server
              # process. Resolve it here, the same lazy require Woods.extract!
              # uses — otherwise every pipeline_extract run dies in the
              # background with NameError.
              require_relative '../extractor' unless defined?(Woods::Extractor)
              extractor = Woods::Extractor.new(output_dir: output_dir)
              incremental ? extractor.extract_changed(files) : extractor.extract_all
            end

            next Woods::MCP::Server.send(
              :run_pipeline_in_background,
              kind: :extraction, tool: 'pipeline_extract', lock: lock,
              task_store: task_store, respond: respond, respond_err: respond_err, runner: run_extraction,
              started: -> { guard&.record!(:extraction) },
              started_message: 'Extraction pipeline started in background thread'
            )
          end
        end

        # The same lock every other writer against this index uses —
        # `woods:extract`/`incremental`/`refresh` and the watch daemon all
        # build it from the daemon's constants (see CLAUDE.md, "writers
        # serialize on PipelineLock").
        #
        # @param output_dir [String, Pathname] index directory
        # @return [Woods::Coordination::PipelineLock]
        def build_extraction_lock(output_dir)
          require_relative '../coordination/pipeline_lock'
          require_relative '../coordination/lock_heartbeat'
          require_relative '../watch/daemon'

          Woods::Coordination::PipelineLock.new(
            lock_dir: output_dir.to_s,
            name: Woods::Watch::Daemon::LOCK_NAME,
            stale_timeout: Woods::Watch::Daemon::LOCK_STALE_TIMEOUT
          )
        end

        # Poll for the lock until {PIPELINE_LOCK_WAIT} elapses. Monotonic, so
        # a clock adjustment mid-wait cannot stretch or shrink the window.
        #
        # @param lock [Woods::Coordination::PipelineLock]
        # @return [Boolean] whether the lock was acquired
        def acquire_lock_briefly(lock)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PIPELINE_LOCK_WAIT
          acquired = lock.acquire
          until acquired || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            sleep 0.1
            acquired = lock.acquire
          end
          acquired
        end

        # Build the cooldown-gate error for pipeline_extract/pipeline_embed,
        # or nil when the operation may proceed.
        #
        # `PipelineGuard#allow?` fails closed on state it cannot verify
        # (corrupt or permission-denied), which reads identically to a
        # genuine, elapsing cooldown from the boolean alone. Reporting
        # `:rate_limited, retry_after_seconds: 300` for state that will
        # never resolve on its own is the inaccurate public metadata this
        # closes — `PipelineGuard#state_status` distinguishes why, and the
        # tool error now says so.
        #
        # @param guard [Woods::Operator::PipelineGuard, nil]
        # @param operation [Symbol] :extraction or :embedding
        # @param tool [String] tool name, for the error payload
        # @return [MCP::Tool::Response, nil]
        def cooldown_error(guard, operation, tool)
          return nil unless guard
          return nil if guard.allow?(operation)

          case guard.state_status
          when :corrupt
            # `pipeline_repair`'s `reset_cooldowns` action deletes state by
            # key and cannot act on content it cannot parse, so it will not
            # clear this — the fix is replacing or removing the state file
            # directly.
            error_response(
              'Pipeline cooldown state is corrupt, so the cooldown cannot be verified. ' \
              'Inspect and replace (or remove) pipeline_guard.json in the operator state directory.',
              code: :cooldown_state_corrupt, tool: tool
            )
          when :permission_denied
            error_response(
              'Pipeline cooldown state is unreadable (permission denied), so the cooldown cannot be verified. ' \
              'Check the operator state directory permissions.',
              code: :cooldown_state_unreadable, tool: tool
            )
          else
            error_response(
              "#{operation == :extraction ? 'Extraction' : 'Embedding'} is rate-limited. Try again later.",
              code: :rate_limited, tool: tool, retry_after_seconds: 300
            )
          end
        end

        def define_pipeline_embed_tool(server, operator, respond, respond_err, op_missing, task_store)
          cooldown = method(:cooldown_error)
          server.define_tool(
            name: 'pipeline_embed',
            description: 'Trigger embedding generation for extracted units. Checks rate limits before proceeding.',
            input_schema: {
              properties: {
                incremental: { type: 'boolean', description: 'Embed only new/changed units (default: false)' }
              }
            }
          ) do |server_context:, incremental: nil|
            next op_missing.call('pipeline_embed') unless operator

            guard = operator[:pipeline_guard]
            if (blocked = cooldown.call(guard, :embedding, 'pipeline_embed'))
              next blocked
            end

            # Acquire the in-process lock first so a refused "already
            # running" request doesn't burn the cooldown clock.
            unless Woods::MCP::Server.send(:pipeline_start, :embedding)
              next respond_err.call(
                'Embedding pipeline is already running. Wait for it to complete.',
                code: :already_running,
                tool: 'pipeline_embed'
              )
            end

            # Cross-PROCESS serialization, mirroring pipeline_extract (#170):
            # embedding writes the checkpoint, dumps and metadata into the
            # same index directory, and the rake embed twins (`woods:embed`,
            # `woods:embed_incremental`) already serialize on the on-disk
            # PipelineLock — one lock domain per index. An unlocked MCP embed
            # was free to interleave with any of them. Same short acquire:
            # contention becomes a clear tool error the caller can retry.
            #
            # A nil/duck-typed configuration (no output_dir) yields no lock —
            # there is no known lock domain, and the embed below fails in the
            # background exactly as it always has on an unconfigured host.
            config = Woods.configuration
            output_dir = config.output_dir if config.respond_to?(:output_dir)
            lock = output_dir && Woods::MCP::Server.send(:build_extraction_lock, output_dir)
            if lock && !Woods::MCP::Server.send(:acquire_lock_briefly, lock)
              Woods::MCP::Server.send(:pipeline_finish, :embedding)
              next respond_err.call(
                'Another writer holds the extraction lock (a rake task or the watch daemon ' \
                'is writing this index). Try again shortly.',
                code: :locked,
                tool: 'pipeline_embed'
              )
            end

            run_embed = lambda do
              # Share the rake-task wiring so the MCP path picks up the
              # provider-tuned TextPreparer + token-aware chunker. Without
              # this, MCP-triggered embedding still hit Ollama's "input
              # length exceeds context length" error after the rake path
              # was fixed in PR #70.
              indexer = Woods::Tasks.build_embed_indexer
              incremental ? indexer.index_incremental : indexer.index_all
            end

            next Woods::MCP::Server.send(
              :run_pipeline_in_background,
              kind: :embedding, tool: 'pipeline_embed', lock: lock,
              task_store: task_store, respond: respond, respond_err: respond_err, runner: run_embed,
              started: -> { guard&.record!(:embedding) },
              started_message: 'Embedding pipeline started in background thread'
            )
          end
        end

        # Run a pipeline on a background thread and answer the caller.
        #
        # Both pipeline tools reached this point with the same shape: a lock
        # they may or may not hold, a runner lambda, and the need to answer
        # immediately because a full run takes minutes. What differs now is
        # *how* they answer.
        #
        # When the client declared the Tasks extension, the answer is a durable
        # `CreateTaskResult`. That is the whole point of the extension here: the
        # handle outlives this process, so a client that disconnects mid-run can
        # reconnect and still learn whether extraction succeeded — and if the
        # process dies, {Tasks::Store} resolves the orphaned record to `failed`
        # instead of leaving an agent polling a run that no longer exists.
        #
        # When it did not, the answer is exactly what it always was. The spec is
        # explicit that a task must never go to a client that did not opt in:
        # such a client would read the handle as the final result and report a
        # completed run that had not started.
        #
        # @param kind [Symbol] :extraction or :embedding, for the in-process lock
        # @param tool [String] tool name, for the task record and error text
        # @param lock [Woods::Coordination::PipelineLock, nil]
        # @param task_store [Tasks::Store, nil] nil disables the task path
        # @param respond [Method] the text-response builder
        # @param runner [Proc] the actual work
        # @param started_message [String] legacy fire-and-forget message
        # @return [Hash, MCP::Tool::Response]
        def run_pipeline_in_background(kind:, tool:, lock:, task_store:, respond:, respond_err:, runner:, started:,
                                       started_message:)
          task = create_pipeline_task(task_store, tool)
          started.call

          Thread.new do
            # Heartbeat, like the rake writers: a full run on a large host can
            # outlive the lock's stale window, and an untouched lock would be
            # retired by the next contender mid-run — recreating the two-writer
            # clobber.
            if lock
              Woods::Coordination::LockHeartbeat.run(lock) { runner.call }
            else
              runner.call
            end
            task_store&.complete!(task.id, result: pipeline_task_result(tool)) if task
          rescue StandardError, ScriptError => e
            # ScriptError (SyntaxError, LoadError) is not a StandardError, and
            # +runner.call+ can lazily +require_relative+ the extractor — a
            # half-typed file must degrade this background thread, not kill it
            # silently while the task record sits at "working" until pid-death
            # (see the "rescue ScriptError anywhere a reload can happen" rule).
            logger = defined?(Rails) ? Rails.logger : Logger.new($stderr)
            logger.error("[Woods] Pipeline #{kind} failed: #{e.message}")
            # Recording the failure is the half that was missing: previously the
            # error reached a log the agent cannot read, and the tool had
            # already reported success.
            task_store&.fail!(task.id, message: "#{e.class}: #{e.message}") if task
          ensure
            lock&.release
            Woods::MCP::Server.send(:pipeline_finish, kind)
          end

          return Tasks::Extension.create_task_result(task) if task

          respond.call(JSON.pretty_generate({ status: 'started', message: started_message }))
        rescue SystemCallError, IOError => e
          lock&.release
          Woods::MCP::Server.send(:pipeline_finish, kind)
          respond_err.call(
            'The task could not be durably recorded, so the pipeline was not started.',
            code: :task_store_unavailable,
            tool: tool,
            exception: e.class.name
          )
        end

        # Mint a task record, or return nil to take the legacy path.
        #
        # Nil only when the client did not opt in. Once a client opts in, task
        # durability is part of the response contract; a write failure propagates
        # to {run_pipeline_in_background}, which fails closed before work starts.
        #
        # @return [Tasks::Store::Task, nil]
        def create_pipeline_task(task_store, tool)
          return nil unless task_store && Tasks::RequestCapture.tasks_requested?

          task_store.create!(tool: tool)
        end

        # What `tasks/get` hands back on success — shaped like the synchronous
        # tool result the caller would have received had it waited.
        def pipeline_task_result(tool)
          {
            'content' => [{ 'type' => 'text', 'text' => "#{tool} completed successfully." }],
            'isError' => false
          }
        end

        # Acquire a pipeline-kind lock atomically. Returns false when
        # another thread is already running that kind of pipeline (so the
        # caller can refuse the new request instead of racing the running
        # pipeline). Module-level state — a single MCP server process
        # serializes its own pipelines.
        def pipeline_start(kind)
          # @pipeline_mutex / @pipeline_in_flight are initialized eagerly in
          # the module body — no lazy `||=` here, which would race under the
          # concurrent HTTP transport.
          @pipeline_mutex.synchronize do
            return false if @pipeline_in_flight[kind]

            @pipeline_in_flight[kind] = true
            true
          end
        end

        def pipeline_finish(kind)
          @pipeline_mutex.synchronize { @pipeline_in_flight.delete(kind) }
        end

        def define_pipeline_status_tool(server, operator, respond, respond_err, op_missing)
          server.define_tool(
            name: 'pipeline_status',
            description: 'Get the current pipeline status: last extraction time, unit counts, staleness.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next op_missing.call('pipeline_status') unless operator

            reporter = operator[:status_reporter]
            unless reporter
              next respond_err.call(
                'Status reporter is not configured.',
                code: :not_configured,
                config_key: 'operator.status_reporter',
                tool: 'pipeline_status'
              )
            end

            status = reporter.report
            respond.call(JSON.pretty_generate(status))
          end
        end

        def define_pipeline_diagnose_tool(server, operator, respond, respond_err, op_missing)
          server.define_tool(
            name: 'pipeline_diagnose',
            description: 'Classify a recent pipeline error and suggest remediation.',
            input_schema: {
              properties: {
                error_class: { type: 'string', description: 'Error class name (e.g. "Timeout::Error")' },
                error_message: { type: 'string', description: 'Error message' }
              },
              required: %w[error_class error_message]
            }
          ) do |error_class:, error_message:, server_context:|
            next op_missing.call('pipeline_diagnose') unless operator

            escalator = operator[:error_escalator]
            unless escalator
              next respond_err.call(
                'Error escalator is not configured.',
                code: :not_configured,
                config_key: 'operator.error_escalator',
                tool: 'pipeline_diagnose'
              )
            end

            # Pass the client-supplied class name so class-keyed patterns
            # (Timeout, Net::, Errno::ENOENT, …) match — a bare
            # StandardError would classify everything as :unknown.
            error = StandardError.new(error_message)
            result = escalator.classify(error, class_name: error_class)
            result[:original_class] = error_class
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_pipeline_repair_tool(server, operator, respond, respond_err, op_missing)
          server.define_tool(
            name: 'pipeline_repair',
            description: 'Attempt to repair pipeline state: clear stale locks, reset rate limits.',
            input_schema: {
              properties: {
                action: {
                  type: 'string',
                  enum: %w[clear_locks reset_cooldowns],
                  description: 'Repair action to perform'
                }
              },
              required: ['action']
            }
          ) do |action:, server_context:|
            next op_missing.call('pipeline_repair') unless operator

            case action
            when 'clear_locks'
              lock = operator[:pipeline_lock]
              if lock
                outcome = lock.retire_stale
                case outcome
                when :cleared
                  respond.call(JSON.pretty_generate({ repaired: true, action: 'clear_locks', outcome: 'cleared' }))
                when :missing
                  respond_err.call(
                    'No pipeline lock exists; nothing was repaired.',
                    code: :lock_missing, tool: 'pipeline_repair', action: action, repaired: false
                  )
                when :not_stale
                  respond_err.call(
                    'The pipeline lock is active and was not cleared.',
                    code: :lock_active, tool: 'pipeline_repair', action: action, repaired: false
                  )
                end
              else
                respond_err.call(
                  'Pipeline lock is not configured.',
                  code: :not_configured,
                  config_key: 'operator.pipeline_lock',
                  tool: 'pipeline_repair'
                )
              end
            when 'reset_cooldowns'
              guard = operator[:pipeline_guard]
              if guard.nil?
                respond_err.call(
                  'Pipeline guard is not configured.',
                  code: :not_configured,
                  config_key: 'operator.pipeline_guard',
                  tool: 'pipeline_repair'
                )
              elsif guard.reset!(:all)
                respond.call(JSON.pretty_generate({ repaired: true, action: action, outcome: 'reset' }))
              else
                respond_err.call(
                  'No pipeline cooldown state exists; nothing was repaired.',
                  code: :cooldown_state_missing, tool: 'pipeline_repair', action: action, repaired: false
                )
              end
            else
              respond_err.call(
                "Unknown repair action: #{action}",
                code: :unsupported_argument,
                tool: 'pipeline_repair',
                argument: 'action',
                value: action,
                allowed: %w[clear_locks reset_cooldowns]
              )
            end
          end
        end

        def define_retrieval_rate_tool(server, feedback_store, respond, fb_missing)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'retrieval_rate',
            description: 'Record a quality rating for a retrieval result (1-5 scale).',
            input_schema: {
              properties: {
                query: { type: 'string', description: 'The query that was used' },
                score: { type: 'integer', description: 'Rating 1-5' },
                comment: { type: 'string', description: 'Optional comment' }
              },
              required: %w[query score]
            }
          ) do |query:, score:, server_context:, comment: nil|
            next fb_missing.call('retrieval_rate') unless feedback_store

            score = coerce_int.call(score)
            feedback_store.record_rating(query: query, score: score, comment: comment)
            respond.call(JSON.pretty_generate({ recorded: true, type: 'rating', query: query, score: score }))
          end
        end

        def define_retrieval_report_gap_tool(server, feedback_store, respond, fb_missing)
          server.define_tool(
            name: 'retrieval_report_gap',
            description: 'Report a missing unit that should have appeared in retrieval results.',
            input_schema: {
              properties: {
                query: { type: 'string', description: 'The query that had poor results' },
                missing_unit: { type: 'string', description: 'Identifier of the expected unit' },
                unit_type: { type: 'string', description: 'Type of the missing unit (model, service, etc.)' }
              },
              required: %w[query missing_unit unit_type]
            }
          ) do |query:, missing_unit:, unit_type:, server_context:|
            next fb_missing.call('retrieval_report_gap') unless feedback_store

            feedback_store.record_gap(query: query, missing_unit: missing_unit, unit_type: unit_type)
            respond.call(JSON.pretty_generate({
                                                recorded: true,
                                                type: 'gap',
                                                missing_unit: missing_unit
                                              }))
          end
        end

        def define_retrieval_explain_tool(server, feedback_store, respond, fb_missing)
          server.define_tool(
            name: 'retrieval_explain',
            description: 'Get feedback statistics: average score, total ratings, gap count.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next fb_missing.call('retrieval_explain') unless feedback_store

            ratings = feedback_store.ratings
            gaps = feedback_store.gaps
            respond.call(JSON.pretty_generate({
                                                total_ratings: ratings.size,
                                                average_score: feedback_store.average_score,
                                                total_gaps: gaps.size,
                                                recent_ratings: ratings.last(5),
                                                recent_gaps: gaps.last(5)
                                              }))
          end
        end

        def define_retrieval_suggest_tool(server, feedback_store, respond, fb_missing)
          server.define_tool(
            name: 'retrieval_suggest',
            description: 'Analyze feedback to suggest improvements: detect patterns in low scores and missing units.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next fb_missing.call('retrieval_suggest') unless feedback_store

            require_relative '../feedback/gap_detector'
            detector = Woods::Feedback::GapDetector.new(feedback_store: feedback_store)
            issues = detector.detect
            respond.call(JSON.pretty_generate({
                                                issues_found: issues.size,
                                                issues: issues
                                              }))
          end
        end

        def define_snapshot_tools(server, snapshot_store, respond, respond_err, snap_missing)
          define_list_snapshots_tool(server, snapshot_store, respond, snap_missing)
          define_snapshot_diff_tool(server, snapshot_store, respond, snap_missing)
          define_unit_history_tool(server, snapshot_store, respond, snap_missing)
          define_snapshot_detail_tool(server, snapshot_store, respond, respond_err, snap_missing)
        end

        def define_list_snapshots_tool(server, snapshot_store, respond, snap_missing)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'list_snapshots',
            description: 'List temporal snapshots of past extraction runs, optionally filtered by branch.',
            input_schema: {
              properties: {
                limit: { type: 'integer', description: 'Maximum results (default: 20)' },
                branch: { type: 'string', description: 'Filter to this branch name' }
              }
            }
          ) do |server_context:, limit: nil, branch: nil|
            next snap_missing.call('list_snapshots') unless snapshot_store

            limit = coerce_int.call(limit)
            results = snapshot_store.list(limit: limit || 20, branch: branch)
            respond.call(JSON.pretty_generate({ snapshot_count: results.size, snapshots: results }))
          end
        end

        def define_snapshot_diff_tool(server, snapshot_store, respond, snap_missing)
          server.define_tool(
            name: 'snapshot_diff',
            description: 'Compare two extraction snapshots by git SHA. Returns lists of added, modified, and deleted units.',
            input_schema: {
              properties: {
                sha_a: { type: 'string', description: 'Git SHA of the "before" snapshot' },
                sha_b: { type: 'string', description: 'Git SHA of the "after" snapshot' }
              },
              required: %w[sha_a sha_b]
            }
          ) do |sha_a:, sha_b:, server_context:|
            next snap_missing.call('snapshot_diff') unless snapshot_store

            result = snapshot_store.diff(sha_a, sha_b)
            respond.call(JSON.pretty_generate({
                                                sha_a: sha_a, sha_b: sha_b,
                                                added: result[:added].size,
                                                modified: result[:modified].size,
                                                deleted: result[:deleted].size,
                                                details: result
                                              }))
          end
        end

        def define_unit_history_tool(server, snapshot_store, respond, snap_missing)
          coerce_int = method(:coerce_integer)
          server.define_tool(
            name: 'unit_history',
            description: 'Show the history of a single unit across extraction snapshots. Tracks when source changed.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier (e.g. "User", "PostsController")' },
                limit: { type: 'integer', description: 'Maximum entries (default: 20)' }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:, limit: nil|
            next snap_missing.call('unit_history') unless snapshot_store

            limit = coerce_int.call(limit)
            entries = snapshot_store.unit_history(identifier, limit: limit || 20)
            respond.call(JSON.pretty_generate({
                                                identifier: identifier,
                                                versions: entries.size,
                                                history: entries
                                              }))
          end
        end

        def define_snapshot_detail_tool(server, snapshot_store, respond, respond_err, snap_missing)
          server.define_tool(
            name: 'snapshot_detail',
            description: 'Get full metadata for a specific extraction snapshot by git SHA.',
            input_schema: {
              properties: {
                git_sha: { type: 'string', description: 'Git SHA of the snapshot' }
              },
              required: ['git_sha']
            }
          ) do |git_sha:, server_context:|
            next snap_missing.call('snapshot_detail') unless snapshot_store

            snapshot = snapshot_store.find(git_sha)
            if snapshot
              respond.call(JSON.pretty_generate(snapshot))
            else
              respond_err.call(
                "Snapshot not found for git SHA: #{git_sha}",
                code: :not_found,
                tool: 'snapshot_detail',
                git_sha: git_sha,
                hint: 'Use `list_snapshots` to see available SHAs.'
              )
            end
          end
        end

        def define_notion_sync_tool(server, reader, index_dir, respond, respond_err)
          server.define_tool(
            name: 'notion_sync',
            description: 'Sync extracted codebase data (Data Models + Columns) to Notion databases. ' \
                         'Requires notion_api_token and notion_database_ids to be configured.',
            input_schema: {
              type: 'object',
              properties: {}
            }
          ) do |server_context:|
            config = Woods.configuration
            # Mirror notion_wired? (which gates registration) and the
            # Exporter via the shared resolver: a non-blank NOTION_API_TOKEN
            # env var satisfies the token requirement (reading config alone
            # rejected ENV-only hosts even though the tool was registered for
            # them), while a blank env var is treated as absent.
            if Woods.resolve_notion_token(config).nil?
              next respond_err.call(
                'notion_api_token is not configured. Set it in Woods.configure or via the NOTION_API_TOKEN env var.',
                code: :not_configured,
                config_key: 'notion_api_token',
                doc_link: 'docs/NOTION_INTEGRATION.md',
                tool: 'notion_sync'
              )
            end

            if (config.notion_database_ids || {}).empty?
              next respond_err.call(
                'notion_database_ids is not configured. Set it in Woods.configure.',
                code: :not_configured,
                config_key: 'notion_database_ids',
                doc_link: 'docs/NOTION_INTEGRATION.md',
                tool: 'notion_sync'
              )
            end

            require_relative '../notion/exporter'
            exporter = Woods::Notion::Exporter.new(index_dir: index_dir, reader: reader)
            stats = exporter.sync_all

            respond.call(JSON.pretty_generate({
                                                synced: true,
                                                data_models: stats[:data_models],
                                                columns: stats[:columns],
                                                errors: stats[:errors].first(10)
                                              }))
          rescue StandardError => e
            respond_err.call(
              "Notion sync failed: #{e.message}",
              code: :api_error,
              tool: 'notion_sync'
            )
          end
        end

        def build_resource_templates
          [
            ::MCP::ResourceTemplate.new(
              uri_template: 'codebase://unit/{identifier}',
              name: 'unit',
              description: 'Look up a single code unit by identifier',
              mime_type: 'application/json'
            ),
            ::MCP::ResourceTemplate.new(
              uri_template: 'codebase://type/{type}',
              name: 'units-by-type',
              description: 'List all code units of a given type (e.g. model, controller, service)',
              mime_type: 'application/json'
            )
          ]
        end

        def build_resources
          [
            ::MCP::Resource.new(
              uri: 'codebase://manifest',
              name: 'manifest',
              description: 'Extraction manifest with version info, unit counts, and git metadata',
              mime_type: 'application/json'
            ),
            ::MCP::Resource.new(
              uri: 'codebase://graph',
              name: 'dependency-graph',
              description: 'Full dependency graph with nodes, edges, and type index',
              mime_type: 'application/json'
            )
          ]
        end

        def define_woods_status_tool(server, reader, retriever, index_dir, bootstrap_state, respond)
          server.define_tool(
            name: 'woods_status',
            description: 'Diagnose whether the Woods index and server are healthy. Returns extraction metadata ' \
                         '(last run, unit counts, git SHA, staleness in seconds), retriever/embedding configuration, ' \
                         'bootstrap state (hydrated / degraded / failed + reason), feature flags, and a ready flag. ' \
                         'Call this first on cold connect to learn what the server knows.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            _ = server_context
            status = Woods::MCP::Server.build_status(
              reader: reader, retriever: retriever, index_dir: index_dir,
              bootstrap_state: bootstrap_state
            )
            respond.call(JSON.pretty_generate(status))
          end
        end

        public

        # Build the woods_status payload. Exposed at module level so specs (and future
        # console/unified-server entry points) can assemble the same shape without
        # reaching through the MCP::Server internals.
        #
        # +features.embedding_model+ / +features.embedding_provider+ /
        # +features.vector_store+ prefer the ResolvedConfig captured at embed time
        # (+bootstrap_state.resolved_config+, which is read back from +woods.json+)
        # over +Woods.configuration+, whose defaults can contradict the actual
        # provider in use. Without this, operators debugging "wrong provider" see
        # status claiming +embedding_model: "text-embedding-3-small"+ next to
        # +embedding_provider: "ollama"+ and reasonably distrust every field.
        def build_status(reader:, retriever:, index_dir:, bootstrap_state: nil)
          # Pin the generation across the whole payload. Without this the
          # manifest can be read at generation N and `generation_fields` then
          # report N+1 — a status report that describes counts from one index
          # while announcing the number of another, which is precisely the
          # confusion this tool exists to resolve.
          return build_status_payload(reader, retriever, index_dir, bootstrap_state) unless
            reader.respond_to?(:with_pinned_generation)

          reader.with_pinned_generation do
            build_status_payload(reader, retriever, index_dir, bootstrap_state)
          end
        end

        def build_status_payload(reader, retriever, index_dir, bootstrap_state)
          manifest = safe_manifest(reader)
          extracted_at = manifest && manifest['extracted_at']
          staleness = staleness_seconds(extracted_at)
          # Tolerate a nil Woods.configuration — specs that reset it between
          # runs can leave a transient nil window, and build_status should
          # still produce a readable payload during that window.
          config = Woods.configuration || Woods::Configuration.new
          resolved = bootstrap_state&.resolved_config

          {
            ready: manifest && !manifest['counts'].to_h.empty?,
            server: {
              name: 'woods',
              version: Woods::VERSION,
              index_dir: index_dir.to_s,
              update: Woods::UpdateCheck.status_hash
            },
            index: index_section(manifest, extracted_at, staleness, index_dir, reader),
            watch: watch_section(index_dir),
            retriever: {
              configured: !retriever.nil?,
              class: retriever&.class&.name
            },
            bootstrap: bootstrap_state&.to_h,
            features: features_from(config, resolved)
          }
        end

        private

        # Assemble the +index+ sub-hash of woods_status, including a staleness
        # gate that compares +manifest.git_sha+ against the current HEAD. The
        # manifest captures +git_sha+ / +gemfile_lock_sha+ / +schema_sha+ at
        # extraction time; until this change nothing compared them against the
        # live working tree, so an agent asking questions after 40 uncommitted
        # changes and an MCP restart silently got pre-change answers.
        #
        # +git_sha_matches_head+ is a tri-state:
        #   - true      — manifest.git_sha == current HEAD
        #   - false     — mismatch (stale)
        #   - nil       — couldn't resolve (not a git repo, git unavailable,
        #                 or manifest has no git_sha)
        #
        # When stale, +head_git_sha+ carries the live HEAD so operators can
        # diff directly. This is an observability signal, not a hard gate —
        # hard-refusing responses would be much more disruptive than a loudly-
        # visible staleness flag that agents can branch on.
        def index_section(manifest, extracted_at, staleness, index_dir, reader = nil)
          base = {
            extracted_at: extracted_at,
            staleness_seconds: staleness,
            rails_version: manifest && manifest['rails_version'],
            ruby_version: manifest && manifest['ruby_version'],
            total_units: manifest && manifest['total_units'],
            counts: (manifest && manifest['counts']) || {},
            git_sha: manifest && manifest['git_sha'],
            git_branch: manifest && manifest['git_branch'],
            gemfile_lock_sha: manifest && manifest['gemfile_lock_sha'],
            schema_sha: manifest && manifest['schema_sha']
          }

          base.merge!(generation_fields(index_dir, reader))
          base.merge!(working_tree_fields(index_dir))

          manifest_sha = manifest && manifest['git_sha']
          head_sha = manifest_sha ? resolve_head_sha(index_dir) : nil
          return base unless head_sha

          base[:head_git_sha] = head_sha
          base[:git_sha_matches_head] = (manifest_sha == head_sha)
          base
        end

        # The generation the index is published at.
        #
        # Every extraction mode that writes the *unit* index bumps this as its
        # last write, so it answers "has the index moved?" without comparing
        # timestamps — which `staleness_seconds` can't, since it measures
        # wall-clock age rather than whether anything changed.
        #
        # One carve-out: `woods:extract_framework` writes only `rails_source/`
        # and does not bump, so a framework re-extraction leaves this number
        # where it was. That is deliberate — framework sources are pinned by the
        # `Gemfile.lock`, reported separately above, and treating them as an
        # index generation would invalidate every reader's cache for data that
        # changes when dependencies do, not when the app does.
        #
        # @return [Hash]
        def generation_fields(index_dir, reader = nil)
          return {} unless index_dir

          marker = Woods::Generation.new(output_dir: index_dir).current
          return { generation: nil } if marker.number.zero?

          fields = { generation: marker.number,
                     generation_updated_at: marker.updated_at,
                     generation_reason: marker.reason }
          fields.merge(served_generation_fields(marker, reader))
        rescue StandardError
          {}
        end

        # What the *reader* is actually serving, which is not always what is
        # published.
        #
        # `build_status` pins the reader so the manifest and counts above come
        # from one generation, but this method reads `generation.json` from
        # disk — so a publish landing mid-call would otherwise report a
        # generation number beside counts from the previous one, the exact
        # mismatch the pin is there to remove. When they differ, say so instead
        # of quietly picking one.
        def served_generation_fields(marker, reader)
          return {} unless reader.respond_to?(:loaded_generation)

          served = reader.loaded_generation
          return {} if served.nil? || served == marker.number

          { served_generation: served, generation_lag: marker.number - served }
        rescue StandardError
          {}
        end

        # Whether the working tree has uncommitted changes, and a fingerprint
        # of them.
        #
        # `git_sha_matches_head` only sees *committed* HEAD, so an agent
        # working through forty uncommitted edits could be told the index
        # matches HEAD while every answer described the tree before those
        # edits. `working_tree_dirty` is the fix for that.
        #
        # The fingerprint is a digest of `git status --porcelain` *as of this
        # call*. Nothing records the digest the index was built at, so it does
        # not answer "is this the same dirty state the index describes" — it
        # gives a caller a stable identity for the current dirty state, so two
        # of its own calls can be compared to detect the tree moving underneath
        # it. Pair it with `generation` to tell "tree changed, index followed"
        # from "tree changed, index has not caught up".
        #
        # @return [Hash]
        def working_tree_fields(index_dir)
          porcelain = resolve_working_tree_status(index_dir)
          return {} if porcelain.nil?

          { working_tree_dirty: !porcelain.empty?,
            working_tree_fingerprint: Digest::SHA256.hexdigest(porcelain)[0, 16] }
        end

        # `git status --porcelain` for the repo containing +index_dir+, or nil
        # when that can't be answered.
        #
        # capture3, not capture2e: stderr still must not reach the stdio
        # transport, but folding it into stdout makes any warning git emits on a
        # successful run — a stale index.lock notice, a detached-HEAD advisory,
        # `core.fsmonitor` chatter — part of the "porcelain" output. A clean tree
        # then reports dirty, and the fingerprint changes with the warning rather
        # than with the code.
        def resolve_working_tree_status(index_dir)
          return nil unless index_dir

          dir = index_dir.to_s
          return nil unless File.directory?(dir)

          output, _stderr, status = Open3.capture3('git', '-C', dir, 'status', '--porcelain')
          status.success? ? output : nil
        rescue StandardError
          nil
        end

        # The watch daemon's state, so an agent can branch on whether anything
        # is keeping this index current.
        #
        # Three states matter and they are not interchangeable: `running`
        # (current, or current within a debounce window), `degraded` (alive but
        # unable to update — the reason says why, and the index is frozen at a
        # known generation), and `stopped`/`absent` (nothing is maintaining
        # this index; fall back to whatever the last explicit run left).
        #
        # @return [Hash]
        def watch_section(index_dir)
          return { state: 'absent' } unless index_dir

          path = File.join(index_dir.to_s, Woods::Watch::Status::FILENAME)
          return { state: 'absent' } unless File.exist?(path)

          # AtomicFile.read: the daemon's reasons contain em dashes, and a
          # US-ASCII default external encoding turns a plain File.read of them
          # into an Encoding::InvalidByteSequenceError — raising out of
          # woods_status entirely rather than degrading it.
          record = JSON.parse(Woods::AtomicFile.read(path))
          # `state` is whatever the daemon last wrote, and a `kill -9`'d daemon
          # leaves `running` behind forever. `alive?` adds the two checks that
          # catch that — the pid still exists and the record is recent — so the
          # payload can distinguish "maintaining this index" from "claimed to be,
          # once". Reported as a separate field rather than by overwriting
          # `state`, because the recorded state and the liveness verdict answer
          # different questions and an operator wants both.
          status = Woods::Watch::Status.new(output_dir: index_dir)
          { state: record['state'], reason: record['reason'], generation: record['generation'],
            pid: record['pid'], updated_at: record['updated_at'],
            alive: status.alive?, stale_after_seconds: Woods::Watch::Status::STALE_AFTER,
            last_action: record['last_action'], last_duration_ms: record['last_duration_ms'] }
        rescue StandardError
          { state: 'absent' }
        end

        # Resolve the current HEAD SHA for the git repo containing +index_dir+.
        # Returns nil when git is unavailable or +index_dir+ is not in a repo —
        # callers treat nil as "can't compare" rather than "mismatch".
        #
        # capture3 keeps git's stderr out of the MCP stdio transport — clients
        # that parse stderr for protocol framing can't tolerate stray lines —
        # *and* out of the SHA. capture2e folded them together, so a warning on
        # an otherwise successful `rev-parse` (a stale `index.lock` notice, a
        # `core.fsmonitor` complaint) was concatenated into the value this
        # method returns and compared against the manifest as if it were a SHA.
        # Same hazard as {#resolve_working_tree_status}, one probe over.
        def resolve_head_sha(index_dir)
          return nil unless index_dir

          dir = index_dir.to_s
          return nil unless File.directory?(dir)

          output, _stderr, status = Open3.capture3('git', '-C', dir, 'rev-parse', 'HEAD')
          status.success? ? output.strip : nil
        rescue Errno::ENOENT, Errno::EACCES
          # git not installed or not executable on this host — equivalent to
          # "can't compare". Any other exception is a genuine bug and should
          # propagate.
          nil
        end

        # Assemble the +features+ sub-hash of woods_status, preferring the
        # ResolvedConfig captured at embed time over live {Woods::Configuration}.
        #
        # Fields that read from resolved+config (when present): embedding_model,
        # embedding_provider, vector_store. Everything else is host-process
        # state (snapshots_enabled, notion_configured, session_tracer_enabled)
        # and comes from the running config.
        #
        # +console_mcp_enabled+ is intentionally omitted — the index MCP process
        # has no visibility into the host Rails app's Woods initializer, so
        # historic status payloads always reported +false+ regardless of the
        # actual console MCP state. Advertising a misleading field is worse
        # than not advertising it at all.
        def features_from(config, resolved)
          provider_hash = resolved&.embedding_provider || {}
          resolved_provider = resolved_provider_symbol(provider_hash[:class])
          resolved_model = provider_hash[:model]
          resolved_vector = resolved&.stores&.dig(:vector_store)

          {
            embedding_model: resolved_model || (config.respond_to?(:embedding_model) ? config.embedding_model : nil),
            embedding_provider: presence(resolved_provider ||
              (config.respond_to?(:embedding_provider) ? config.embedding_provider : nil)),
            vector_store: presence(resolved_vector ||
              (config.respond_to?(:vector_store) ? config.vector_store : nil)),
            session_tracer_enabled: config.respond_to?(:session_tracer_enabled) ? config.session_tracer_enabled : false,
            snapshots_enabled: config.respond_to?(:enable_snapshots) ? config.enable_snapshots : false,
            notion_configured: config.respond_to?(:notion_api_token) && !presence(config.notion_api_token).nil?
          }
        end

        # Convert a fully-qualified provider class name (as serialised in
        # woods.json — e.g. +"Woods::Embedding::Provider::Ollama"+) into the
        # short symbol form used by +Woods.configuration.embedding_provider+
        # (+:ollama+, +:openai+). Returns nil when +class_name+ is unknown or
        # absent so callers fall back to the live config value.
        def resolved_provider_symbol(class_name)
          return nil if class_name.nil? || class_name.empty?

          case class_name
          when /Ollama\z/ then :ollama
          when /OpenAI\z/ then :openai
          end
        end

        # Return a Hash of manifest content, or nil if unreadable.
        def safe_manifest(reader)
          reader.manifest
        rescue StandardError
          nil
        end

        # Seconds since extraction. Returns nil if timestamp is missing or unparsable.
        def staleness_seconds(iso8601)
          return nil if iso8601.nil? || iso8601.empty?

          (Time.now - Time.parse(iso8601)).to_i
        rescue ArgumentError
          nil
        end

        def presence(value)
          return nil if value.nil?
          return nil if value.respond_to?(:empty?) && value.empty?

          value.to_s
        end

        def register_resource_handler(server, reader)
          server.resources_read_handler do |params|
            uri = params[:uri]
            kind, target = parse_resource_uri(uri)
            raise ::MCP::Server::ResourceNotFoundError.new(uri, params) unless kind

            payload = resource_payload(reader, kind, target)
            raise ::MCP::Server::ResourceNotFoundError.new(uri, params) if payload.nil?

            [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(payload) }]
          rescue ::MCP::Server::ResourceNotFoundError
            raise
          rescue JSON::ParserError, SystemCallError, IOError, TypeError => e
            raise corrupt_resource_error(uri, params, e)
          end
        end

        def parse_resource_uri(uri)
          return [:manifest, nil] if uri == 'codebase://manifest'
          return [:graph, nil] if uri == 'codebase://graph'
          return unless uri.is_a?(String)

          parsed = URI.parse(uri)
          return unless parsed.scheme == 'codebase'
          return unless %w[unit type].include?(parsed.host)
          return if parsed.userinfo || parsed.port || parsed.query || parsed.fragment || parsed.opaque

          raw_target = parsed.path.to_s.delete_prefix('/')
          return if raw_target.empty? || raw_target.include?('/')

          target = URI::DEFAULT_PARSER.unescape(raw_target).force_encoding(Encoding::UTF_8)
          return unless target.valid_encoding?
          return if target.match?(%r{[%\\/\x00-\x1f\x7f]})
          return if %w[. ..].include?(target)

          [parsed.host.to_sym, target]
        rescue URI::InvalidURIError
          nil
        end

        def resource_payload(reader, kind, target)
          case kind
          when :manifest
            reader.manifest.tap { |value| raise TypeError unless value.is_a?(Hash) }
          when :graph
            reader.raw_graph_data.tap do |value|
              raise TypeError unless value.is_a?(Hash) && value['nodes'].is_a?(Hash) && value['edges'].is_a?(Hash)
            end
          when :unit
            reader.find_unit(target).tap do |value|
              raise TypeError if value && (!value.is_a?(Hash) || value['identifier'] != target)
            end
          when :type
            return nil unless IndexReader::TYPE_TO_DIR.key?(target)

            reader.list_units(type: target).tap do |value|
              raise TypeError unless value.is_a?(Array) && value.all?(Hash)
            end
          end
        end

        def corrupt_resource_error(uri, params, original_error)
          ::MCP::Server::RequestHandlerError.new(
            'Resource artifact is unavailable or malformed.',
            params,
            error_type: :internal_error,
            original_error: original_error,
            error_code: ::JsonRpcHandler::ErrorCode::INTERNAL_ERROR,
            error_data: { uri: uri, error_code: 'corrupt_artifact' }
          )
        end
      end
    end
  end
end
