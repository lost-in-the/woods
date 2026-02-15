# frozen_string_literal: true

require 'mcp'
require 'set'
require_relative 'index_reader'

module CodebaseIndex
  module MCP
    # Builds an MCP::Server with 20 tools, 2 resources, and 2 resource templates for querying
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
        def build(index_dir:, retriever: nil, operator: nil, feedback_store: nil)
          reader = IndexReader.new(index_dir)
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

          define_lookup_tool(server, reader, respond)
          define_search_tool(server, reader, respond)
          define_dependencies_tool(server, reader, respond)
          define_dependents_tool(server, reader, respond)
          define_structure_tool(server, reader, respond)
          define_graph_analysis_tool(server, reader, respond)
          define_pagerank_tool(server, reader, respond)
          define_framework_tool(server, reader, respond)
          define_recent_changes_tool(server, reader, respond)
          define_reload_tool(server, reader, respond)
          define_retrieve_tool(server, retriever, respond)
          define_operator_tools(server, operator, respond)
          define_feedback_tools(server, feedback_store, respond)
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

        def define_lookup_tool(server, reader, respond)
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
          ) do |identifier:, _server_context:, include_source: nil, sections: nil|
            unit = reader.find_unit(identifier)
            if unit
              always_include = %w[type identifier file_path namespace]
              filtered = unit
              filtered = filtered.except('source_code') if include_source == false
              if sections&.any?
                allowed = (always_include + sections).to_set
                filtered = filtered.slice(*allowed)
              end
              respond.call(JSON.pretty_generate(filtered))
            else
              respond.call("Unit not found: #{identifier}")
            end
          end
        end

        def define_search_tool(server, reader, respond)
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
          ) do |query:, _server_context:, types: nil, fields: nil, limit: nil|
            results = reader.search(
              query,
              types: types,
              fields: fields || %w[identifier],
              limit: limit || 20
            )
            respond.call(JSON.pretty_generate({
                                                query: query,
                                                result_count: results.size,
                                                results: results
                                              }))
          end
        end

        def define_dependencies_tool(server, reader, respond)
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
          ) do |identifier:, _server_context:, depth: nil, types: nil|
            result = reader.traverse_dependencies(
              identifier,
              depth: depth || 2,
              types: types
            )
            if result[:found] == false
              result[:message] =
                "Identifier '#{identifier}' not found in the index. Use 'search' to find valid identifiers."
            end
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_dependents_tool(server, reader, respond)
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
          ) do |identifier:, _server_context:, depth: nil, types: nil|
            result = reader.traverse_dependents(
              identifier,
              depth: depth || 2,
              types: types
            )
            if result[:found] == false
              result[:message] =
                "Identifier '#{identifier}' not found in the index. Use 'search' to find valid identifiers."
            end
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_structure_tool(server, reader, respond)
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
          ) do |_server_context:, detail: nil|
            result = { manifest: reader.manifest }
            result[:summary] = reader.summary if (detail || 'summary') == 'full'
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_graph_analysis_tool(server, reader, respond)
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
                limit: { type: 'integer', description: 'Limit results per section (default: 20)' }
              }
            }
          ) do |_server_context:, analysis: nil, limit: nil|
            data = reader.graph_analysis
            section = analysis || 'all'

            result = if section == 'all'
                       if limit
                         truncated = data.dup
                         %w[orphans dead_ends hubs cycles bridges].each do |key|
                           next unless truncated[key].is_a?(Array)

                           original = truncated[key]
                           truncated[key] = truncate.call(original, limit)
                           if original.size > limit
                             truncated["#{key}_total"] = original.size
                             truncated["#{key}_truncated"] = true
                           end
                         end
                         truncated
                       else
                         data
                       end
                     else
                       single = { section => data[section], 'stats' => data['stats'] }
                       if limit && data[section].is_a?(Array)
                         original = data[section]
                         single[section] = truncate.call(original, limit)
                         if original.size > limit
                           single["#{section}_total"] = original.size
                           single["#{section}_truncated"] = true
                         end
                       end
                       single
                     end

            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_pagerank_tool(server, reader, respond)
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
          ) do |_server_context:, limit: nil, types: nil|
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
            respond.call(JSON.pretty_generate(result))
          end
        end

        def define_framework_tool(server, reader, respond)
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
          ) do |keyword:, _server_context:, limit: nil|
            results = reader.framework_sources(keyword, limit: limit || 20)
            respond.call(JSON.pretty_generate({
                                                keyword: keyword,
                                                result_count: results.size,
                                                results: results
                                              }))
          end
        end

        def define_recent_changes_tool(server, reader, respond)
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
          ) do |_server_context:, limit: nil, types: nil|
            results = reader.recent_changes(limit: limit || 10, types: types)
            respond.call(JSON.pretty_generate({
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
          ) do |_server_context:|
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
          ) do |query:, _server_context:, budget: nil|
            if retriever
              result = retriever.retrieve(query, budget: budget || 8000)
              respond.call(result.context)
            else
              respond.call(
                'Semantic search is not available. Embedding provider is not configured. ' \
                'Use the codebase_search tool for pattern-based search instead.'
              )
            end
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
          ) do |_server_context:, incremental: nil|
            next respond.call('Pipeline operator is not configured.') unless operator

            guard = operator[:pipeline_guard]
            next respond.call('Extraction is rate-limited. Try again later.') if guard && !guard.allow?(:extraction)

            guard&.record!(:extraction)
            mode = incremental ? 'incremental' : 'full'
            respond.call(JSON.pretty_generate({
                                                triggered: true,
                                                mode: mode,
                                                message: "#{mode.capitalize} extraction triggered."
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
          ) do |_server_context:, incremental: nil|
            next respond.call('Pipeline operator is not configured.') unless operator

            guard = operator[:pipeline_guard]
            next respond.call('Embedding is rate-limited. Try again later.') if guard && !guard.allow?(:embedding)

            guard&.record!(:embedding)
            mode = incremental ? 'incremental' : 'full'
            respond.call(JSON.pretty_generate({
                                                triggered: true,
                                                mode: mode,
                                                message: "#{mode.capitalize} embedding triggered."
                                              }))
          end
        end

        def define_pipeline_status_tool(server, operator, respond)
          server.define_tool(
            name: 'pipeline_status',
            description: 'Get the current pipeline status: last extraction time, unit counts, staleness.',
            input_schema: { type: 'object', properties: {} }
          ) do |_server_context:|
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
          ) do |error_class:, error_message:, _server_context:|
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
          ) do |action:, _server_context:|
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
          ) do |query:, score:, _server_context:, comment: nil|
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
          ) do |query:, missing_unit:, unit_type:, _server_context:|
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
          ) do |_server_context:|
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
          ) do |_server_context:|
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
