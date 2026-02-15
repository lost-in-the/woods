# frozen_string_literal: true

require 'mcp'
require 'set'
require_relative 'index_reader'

module CodebaseIndex
  module MCP
    # Builds an MCP::Server with 10 tools, 2 resources, and 2 resource templates for querying
    # CodebaseIndex extraction output.
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
        # @return [MCP::Server] Configured server ready for transport
        def build(index_dir:, retriever: nil)
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
          ) do |identifier:, server_context:, include_source: nil, sections: nil|
            unit = reader.find_unit(identifier)
            if unit
              always_include = %w[type identifier file_path namespace]
              filtered = unit
              filtered = filtered.except('source_code') if include_source == false
              if sections&.any?
                allowed = (always_include + sections).to_set
                filtered = filtered.select { |k, _| allowed.include?(k) }
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
          ) do |query:, server_context:, types: nil, fields: nil, limit: nil|
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
          ) do |identifier:, server_context:, depth: nil, types: nil|
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
          ) do |identifier:, server_context:, depth: nil, types: nil|
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
          ) do |server_context:, detail: nil|
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
          ) do |server_context:, analysis: nil, limit: nil|
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
          ) do |server_context:, limit: nil, types: nil|
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
          ) do |keyword:, server_context:, limit: nil|
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
          ) do |server_context:, limit: nil, types: nil|
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
                'Use the codebase_search tool for pattern-based search instead.'
              )
            end
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
