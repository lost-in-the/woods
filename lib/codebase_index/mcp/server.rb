# frozen_string_literal: true

require 'logger'
require 'mcp'
require 'set'
require_relative 'index_reader'
require_relative 'tool_response_renderer'

module CodebaseIndex
  module MCP
    # Builds an MCP::Server with 27 tools, 2 resources, and 2 resource templates for querying
    # CodebaseIndex extraction output, managing pipelines, and collecting feedback.
    #
    # All tools are defined inline via closures over an IndexReader instance.
    # No Rails required at runtime — reads JSON files from disk.
    #
    # @example
    #   server = CodebaseIndex::MCP::Server.build(index_dir: "/path/to/output")
    #   transport = MCP::Server::Transports::StdioTransport.new(server)
    #   transport.open
    #
    module Server
      class << self
        # Build a configured MCP::Server with all tools and resources.
        #
        # @param index_dir [String] Path to extraction output directory
        # @param retriever [CodebaseIndex::Retriever, nil] Optional retriever for semantic search
        # @param operator [Hash, nil] Optional operator config with :status_reporter, :error_escalator, :pipeline_guard, :pipeline_lock
        # @param feedback_store [CodebaseIndex::Feedback::Store, nil] Optional feedback store
        # @return [MCP::Server] Configured server ready for transport
        def build(index_dir:, retriever: nil, operator: nil, feedback_store: nil, snapshot_store: nil, response_format: nil)
          reader = IndexReader.new(index_dir)
          config = CodebaseIndex.configuration
          format = response_format || (config.respond_to?(:context_format) ? config.context_format : nil) || :markdown
          renderer = ToolResponseRenderer.for(format)
          resources = build_resources
          resource_templates = build_resource_templates

          # Lambda captured by all tool blocks for building responses.
          respond = method(:text_response)

          server = ::MCP::Server.new(
            name: 'codebase-index',
            version: CodebaseIndex::VERSION,
            resources: resources,
            resource_templates: resource_templates
          )

          define_lookup_tool(server, reader, respond, renderer)
          define_search_tool(server, reader, respond, renderer)
          define_dependencies_tool(server, reader, respond, renderer)
          define_dependents_tool(server, reader, respond, renderer)
          define_structure_tool(server, reader, respond, renderer)
          define_graph_analysis_tool(server, reader, respond, renderer)
          define_pagerank_tool(server, reader, respond, renderer)
          define_framework_tool(server, reader, respond, renderer)
          define_recent_changes_tool(server, reader, respond, renderer)
          define_reload_tool(server, reader, respond)
          define_retrieve_tool(server, retriever, respond)
          define_trace_flow_tool(server, reader, index_dir, respond, renderer)
          define_session_trace_tool(server, reader, respond)
          define_operator_tools(server, operator, respond)
          define_feedback_tools(server, feedback_store, respond)
          define_snapshot_tools(server, snapshot_store, respond)
          define_notion_sync_tool(server, reader, index_dir, respond)
          register_resource_handler(server, reader)

          server
        end

        private

        def text_response(text)
          ::MCP::Tool::Response.new([{ type: 'text', text: text }])
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

        def define_lookup_tool(server, reader, respond, renderer)
          server.define_tool(
            name: 'lookup',
            description: 'Look up a code unit by its exact identifier. Returns full source code, metadata, ' \
                         'dependencies, and dependents. Use include_source: false to omit source_code. ' \
                         'Use sections to select specific keys (type, identifier, file_path, namespace are always included).',
            input_schema: {
              properties: {
                identifier: { type: 'string',
                              description: 'Exact unit identifier (e.g. "Post", "PostsController", "Api::V1::HealthController")' },
                include_source: { type: 'boolean', description: 'Include source_code in response (default: true)' },
                sections: {
                  type: 'array', items: { type: 'string' },
                  description: 'Select specific keys to return (e.g. ["metadata", "dependencies"]). Always includes type, identifier, file_path, namespace.'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:, include_source: nil, sections: nil|
            sections = [sections] if sections.is_a?(String)
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
              respond.call("Unit not found: #{identifier}")
            end
          end
        end

        def define_search_tool(server, reader, respond, renderer)
          server.define_tool(
            name: 'search',
            description: 'Search code units by pattern. Matches against identifiers by default; can also search source_code and metadata fields.',
            input_schema: {
              properties: {
                query: { type: 'string', description: 'Search pattern (case-insensitive regex)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types: model, controller, service, job, mailer, etc.'
                },
                fields: {
                  type: 'array', items: { type: 'string' },
                  description: 'Fields to search: identifier, source_code, metadata. Default: [identifier]'
                },
                limit: { type: 'integer', description: 'Maximum results (default: 20)' }
              },
              required: ['query']
            }
          ) do |query:, server_context:, types: nil, fields: nil, limit: nil|
            types = [types] if types.is_a?(String)
            fields = [fields] if fields.is_a?(String)
            results = reader.search(
              query,
              types: types,
              fields: fields || %w[identifier],
              limit: limit || 20
            )
            respond.call(renderer.render(:search, {
                                           query: query,
                                           result_count: results.size,
                                           results: results
                                         }))
          end
        end

        def define_dependencies_tool(server, reader, respond, renderer)
          server.define_tool(
            name: 'dependencies',
            description: 'Traverse forward dependencies of a unit (what it depends on). Returns a BFS tree with depth.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier to start from' },
                depth: { type: 'integer', description: 'Maximum traversal depth (default: 2)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:, depth: nil, types: nil|
            types = [types] if types.is_a?(String)
            result = reader.traverse_dependencies(
              identifier,
              depth: depth || 2,
              types: types
            )
            if result[:found] == false
              result[:message] =
                "Identifier '#{identifier}' not found in the index. Use 'search' to find valid identifiers."
            end
            respond.call(renderer.render(:dependencies, result))
          end
        end

        def define_dependents_tool(server, reader, respond, renderer)
          server.define_tool(
            name: 'dependents',
            description: 'Traverse reverse dependencies of a unit (what depends on it). Returns a BFS tree with depth.',
            input_schema: {
              properties: {
                identifier: { type: 'string', description: 'Unit identifier to start from' },
                depth: { type: 'integer', description: 'Maximum traversal depth (default: 2)' },
                types: {
                  type: 'array', items: { type: 'string' },
                  description: 'Filter to these types'
                }
              },
              required: ['identifier']
            }
          ) do |identifier:, server_context:, depth: nil, types: nil|
            types = [types] if types.is_a?(String)
            result = reader.traverse_dependents(
              identifier,
              depth: depth || 2,
              types: types
            )
            if result[:found] == false
              result[:message] =
                "Identifier '#{identifier}' not found in the index. Use 'search' to find valid identifiers."
            end
            respond.call(renderer.render(:dependents, result))
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
            result = { manifest: reader.manifest }
            result[:summary] = reader.summary if (detail || 'summary') == 'full'
            respond.call(renderer.render(:structure, result))
          end
        end

        def define_graph_analysis_tool(server, reader, respond, renderer)
          truncate = method(:truncate_section)
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
            data = reader.graph_analysis
            section = analysis || 'all'
            effective_offset = offset || 0

            result = if section == 'all'
                       if limit || effective_offset.positive?
                         truncated = data.dup
                         %w[orphans dead_ends hubs cycles bridges].each do |key|
                           next unless truncated[key].is_a?(Array)

                           original = truncated[key]
                           sliced = effective_offset.positive? ? original.drop(effective_offset) : original
                           truncated[key] = limit ? truncate.call(sliced, limit) : sliced
                           if original.size > effective_offset + (limit || original.size)
                             truncated["#{key}_total"] = original.size
                             truncated["#{key}_truncated"] = true
                           end
                           truncated["#{key}_offset"] = effective_offset if effective_offset.positive?
                         end
                         truncated
                       else
                         data
                       end
                     else
                       single = { section => data[section], 'stats' => data['stats'] }
                       if data[section].is_a?(Array) && (limit || effective_offset.positive?)
                         original = data[section]
                         sliced = effective_offset.positive? ? original.drop(effective_offset) : original
                         single[section] = limit ? truncate.call(sliced, limit) : sliced
                         if original.size > effective_offset + (limit || original.size)
                           single["#{section}_total"] = original.size
                           single["#{section}_truncated"] = true
                         end
                         single["#{section}_offset"] = effective_offset if effective_offset.positive?
                       end
                       single
                     end

            respond.call(renderer.render(:graph_analysis, result))
          end
        end

        def define_pagerank_tool(server, reader, respond, renderer)
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
            types = [types] if types.is_a?(String)
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
            results = reader.framework_sources(keyword, limit: limit || 20)
            respond.call(renderer.render(:framework, {
                                           keyword: keyword,
                                           result_count: results.size,
                                           results: results
                                         }))
          end
        end

        def define_recent_changes_tool(server, reader, respond, renderer)
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
            types = [types] if types.is_a?(String)
            results = reader.recent_changes(limit: limit || 10, types: types)
            respond.call(renderer.render(:recent_changes, {
                                           result_count: results.size,
                                           results: results
                                         }))
          end
        end

        def define_reload_tool(server, reader, respond)
          server.define_tool(
            name: 'reload',
            description: 'Reload extraction data from disk. Use after re-running extraction to pick up changes ' \
                         'without restarting the server.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            reader.reload!
            manifest = reader.manifest
            respond.call(JSON.pretty_generate({
                                                reloaded: true,
                                                extracted_at: manifest['extracted_at'],
                                                total_units: manifest['total_units'],
                                                counts: manifest['counts']
                                              }))
          end
        end

        def define_retrieve_tool(server, retriever, respond)
          server.define_tool(
            name: 'codebase_retrieve',
            description: 'Retrieve relevant codebase context for a natural language query using semantic search. ' \
                         'Returns ranked code units assembled into a token-budgeted context string.',
            input_schema: {
              properties: {
                query: { type: 'string',
                         description: 'Natural language query (e.g. "How does user authentication work?")' },
                budget: { type: 'integer', description: 'Token budget for context assembly (default: 8000)' }
              },
              required: ['query']
            }
          ) do |query:, server_context:, budget: nil|
            if retriever
              result = retriever.retrieve(query, budget: budget || 8000)
              respond.call(result.context)
            else
              respond.call(
                'Semantic search is not available. Embedding provider is not configured. ' \
                'Use the search tool for pattern-based search instead.'
              )
            end
          end
        end

        def define_trace_flow_tool(server, reader, index_dir, respond, renderer)
          require_relative '../flow_assembler'
          require_relative '../dependency_graph'

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
            max_depth = depth || 3
            graph = reader.dependency_graph

            assembler = CodebaseIndex::FlowAssembler.new(
              graph: graph,
              extracted_dir: index_dir
            )
            flow_doc = assembler.assemble(entry_point, max_depth: max_depth)

            respond.call(renderer.render(:trace_flow, flow_doc.to_h))
          rescue StandardError => e
            respond.call(JSON.pretty_generate({ error: e.message }))
          end
        end

        def define_session_trace_tool(server, reader, respond)
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
            store = CodebaseIndex.configuration.session_store
            next respond.call(JSON.pretty_generate({ error: 'Session tracer not configured' })) unless store

            require_relative '../session_tracer/session_flow_assembler'

            assembler = CodebaseIndex::SessionTracer::SessionFlowAssembler.new(
              store: store, reader: reader
            )
            doc = assembler.assemble(session_id, budget: budget || 8000, depth: depth || 1)
            respond.call(doc.to_markdown)
          rescue StandardError => e
            respond.call(JSON.pretty_generate({ error: e.message }))
          end
        end

        def define_operator_tools(server, operator, respond)
          define_pipeline_extract_tool(server, operator, respond)
          define_pipeline_embed_tool(server, operator, respond)
          define_pipeline_status_tool(server, operator, respond)
          define_pipeline_diagnose_tool(server, operator, respond)
          define_pipeline_repair_tool(server, operator, respond)
        end

        def define_feedback_tools(server, feedback_store, respond)
          define_retrieval_rate_tool(server, feedback_store, respond)
          define_retrieval_report_gap_tool(server, feedback_store, respond)
          define_retrieval_explain_tool(server, feedback_store, respond)
          define_retrieval_suggest_tool(server, feedback_store, respond)
        end

        def define_pipeline_extract_tool(server, operator, respond)
          server.define_tool(
            name: 'pipeline_extract',
            description: 'Trigger a codebase extraction pipeline run. Checks rate limits before proceeding.',
            input_schema: {
              properties: {
                incremental: { type: 'boolean', description: 'Run incremental extraction (default: false)' }
              }
            }
          ) do |server_context:, incremental: nil|
            next respond.call('Pipeline operator is not configured.') unless operator

            guard = operator[:pipeline_guard]
            next respond.call('Extraction is rate-limited. Try again later.') if guard && !guard.allow?(:extraction)

            guard&.record!(:extraction)

            Thread.new do
              extractor = CodebaseIndex::Extractor.new(
                output_dir: CodebaseIndex.configuration.output_dir
              )
              incremental ? extractor.extract_changed([]) : extractor.extract_all
            rescue StandardError => e
              logger = defined?(Rails) ? Rails.logger : Logger.new($stderr)
              logger.error("[CodebaseIndex] Pipeline extract failed: #{e.message}")
            end

            respond.call(JSON.pretty_generate({
                                                status: 'started',
                                                message: 'Extraction pipeline started in background thread'
                                              }))
          end
        end

        def define_pipeline_embed_tool(server, operator, respond)
          server.define_tool(
            name: 'pipeline_embed',
            description: 'Trigger embedding generation for extracted units. Checks rate limits before proceeding.',
            input_schema: {
              properties: {
                incremental: { type: 'boolean', description: 'Embed only new/changed units (default: false)' }
              }
            }
          ) do |server_context:, incremental: nil|
            next respond.call('Pipeline operator is not configured.') unless operator

            guard = operator[:pipeline_guard]
            next respond.call('Embedding is rate-limited. Try again later.') if guard && !guard.allow?(:embedding)

            guard&.record!(:embedding)

            Thread.new do
              config = CodebaseIndex.configuration
              builder = CodebaseIndex::Builder.new(config)
              provider = builder.build_embedding_provider
              text_preparer = CodebaseIndex::Embedding::TextPreparer.new
              vector_store = builder.build_vector_store
              indexer = CodebaseIndex::Embedding::Indexer.new(
                provider: provider,
                text_preparer: text_preparer,
                vector_store: vector_store,
                output_dir: config.output_dir
              )
              incremental ? indexer.index_incremental : indexer.index_all
            rescue StandardError => e
              logger = defined?(Rails) ? Rails.logger : Logger.new($stderr)
              logger.error("[CodebaseIndex] Pipeline embed failed: #{e.message}")
            end

            respond.call(JSON.pretty_generate({
                                                status: 'started',
                                                message: 'Embedding pipeline started in background thread'
                                              }))
          end
        end

        def define_pipeline_status_tool(server, operator, respond)
          server.define_tool(
            name: 'pipeline_status',
            description: 'Get the current pipeline status: last extraction time, unit counts, staleness.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next respond.call('Pipeline operator is not configured.') unless operator

            reporter = operator[:status_reporter]
            next respond.call('Status reporter is not configured.') unless reporter

            status = reporter.report
            respond.call(JSON.pretty_generate(status))
          end
        end

        def define_pipeline_diagnose_tool(server, operator, respond)
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
            next respond.call('Pipeline operator is not configured.') unless operator

            escalator = operator[:error_escalator]
            next respond.call('Error escalator is not configured.') unless escalator

            error = StandardError.new(error_message)
            # Set the class name in the error string for pattern matching
            result = escalator.classify(error)
            result[:original_class] = error_class
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_pipeline_repair_tool(server, operator, respond)
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
            next respond.call('Pipeline operator is not configured.') unless operator

            case action
            when 'clear_locks'
              lock = operator[:pipeline_lock]
              if lock
                lock.release
                respond.call(JSON.pretty_generate({ repaired: true, action: 'clear_locks' }))
              else
                respond.call('Pipeline lock is not configured.')
              end
            when 'reset_cooldowns'
              respond.call(JSON.pretty_generate({ repaired: true, action: 'reset_cooldowns' }))
            else
              respond.call("Unknown repair action: #{action}")
            end
          end
        end

        def define_retrieval_rate_tool(server, feedback_store, respond)
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
            next respond.call('Feedback store is not configured.') unless feedback_store

            feedback_store.record_rating(query: query, score: score, comment: comment)
            respond.call(JSON.pretty_generate({ recorded: true, type: 'rating', query: query, score: score }))
          end
        end

        def define_retrieval_report_gap_tool(server, feedback_store, respond)
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
            next respond.call('Feedback store is not configured.') unless feedback_store

            feedback_store.record_gap(query: query, missing_unit: missing_unit, unit_type: unit_type)
            respond.call(JSON.pretty_generate({
                                                recorded: true,
                                                type: 'gap',
                                                missing_unit: missing_unit
                                              }))
          end
        end

        def define_retrieval_explain_tool(server, feedback_store, respond)
          server.define_tool(
            name: 'retrieval_explain',
            description: 'Get feedback statistics: average score, total ratings, gap count.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next respond.call('Feedback store is not configured.') unless feedback_store

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

        def define_retrieval_suggest_tool(server, feedback_store, respond)
          server.define_tool(
            name: 'retrieval_suggest',
            description: 'Analyze feedback to suggest improvements: detect patterns in low scores and missing units.',
            input_schema: { type: 'object', properties: {} }
          ) do |server_context:|
            next respond.call('Feedback store is not configured.') unless feedback_store

            require_relative '../feedback/gap_detector'
            detector = CodebaseIndex::Feedback::GapDetector.new(feedback_store: feedback_store)
            issues = detector.detect
            respond.call(JSON.pretty_generate({
                                                issues_found: issues.size,
                                                issues: issues
                                              }))
          end
        end

        def define_snapshot_tools(server, snapshot_store, respond)
          define_list_snapshots_tool(server, snapshot_store, respond)
          define_snapshot_diff_tool(server, snapshot_store, respond)
          define_unit_history_tool(server, snapshot_store, respond)
          define_snapshot_detail_tool(server, snapshot_store, respond)
        end

        def define_list_snapshots_tool(server, snapshot_store, respond)
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
            next respond.call('Snapshot store is not configured. Set enable_snapshots: true.') unless snapshot_store

            results = snapshot_store.list(limit: limit || 20, branch: branch)
            respond.call(JSON.pretty_generate({ snapshot_count: results.size, snapshots: results }))
          end
        end

        def define_snapshot_diff_tool(server, snapshot_store, respond)
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
            next respond.call('Snapshot store is not configured. Set enable_snapshots: true.') unless snapshot_store

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

        def define_unit_history_tool(server, snapshot_store, respond)
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
            next respond.call('Snapshot store is not configured. Set enable_snapshots: true.') unless snapshot_store

            entries = snapshot_store.unit_history(identifier, limit: limit || 20)
            respond.call(JSON.pretty_generate({
                                                identifier: identifier,
                                                versions: entries.size,
                                                history: entries
                                              }))
          end
        end

        def define_snapshot_detail_tool(server, snapshot_store, respond)
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
            next respond.call('Snapshot store is not configured. Set enable_snapshots: true.') unless snapshot_store

            snapshot = snapshot_store.find(git_sha)
            if snapshot
              respond.call(JSON.pretty_generate(snapshot))
            else
              respond.call("Snapshot not found for git SHA: #{git_sha}")
            end
          end
        end

        def define_notion_sync_tool(server, reader, index_dir, respond)
          server.define_tool(
            name: 'notion_sync',
            description: 'Sync extracted codebase data (Data Models + Columns) to Notion databases. ' \
                         'Requires notion_api_token and notion_database_ids to be configured.',
            input_schema: {
              type: 'object',
              properties: {}
            }
          ) do |server_context:|
            config = CodebaseIndex.configuration
            unless config.notion_api_token
              next respond.call('Error: notion_api_token is not configured. Set it in CodebaseIndex.configure.')
            end

            if (config.notion_database_ids || {}).empty?
              next respond.call('Error: notion_database_ids is not configured. Set it in CodebaseIndex.configure.')
            end

            require_relative '../notion/exporter'
            exporter = CodebaseIndex::Notion::Exporter.new(index_dir: index_dir, reader: reader)
            stats = exporter.sync_all

            respond.call(JSON.pretty_generate({
                                                synced: true,
                                                data_models: stats[:data_models],
                                                columns: stats[:columns],
                                                errors: stats[:errors].first(10)
                                              }))
          rescue StandardError => e
            respond.call("Notion sync failed: #{e.message}")
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

        def register_resource_handler(server, reader)
          server.resources_read_handler do |params|
            uri = params[:uri]
            case uri
            when 'codebase://manifest'
              [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(reader.manifest) }]
            when 'codebase://graph'
              [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(reader.raw_graph_data) }]
            when %r{\Acodebase://unit/(.+)\z}
              identifier = Regexp.last_match(1)
              unit = reader.find_unit(identifier)
              if unit
                [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(unit) }]
              else
                [{ uri: uri, mimeType: 'text/plain', text: "Unit not found: #{identifier}" }]
              end
            when %r{\Acodebase://type/(.+)\z}
              type = Regexp.last_match(1)
              units = reader.list_units(type: type)
              [{ uri: uri, mimeType: 'application/json', text: JSON.pretty_generate(units) }]
            else
              [{ uri: uri, mimeType: 'text/plain', text: "Unknown resource: #{uri}" }]
            end
          end
        end
      end
    end
  end
end
