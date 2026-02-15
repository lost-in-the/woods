# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/version'
require 'codebase_index/dependency_graph'
require 'codebase_index/mcp/server'

RSpec.describe CodebaseIndex::MCP::Server do
  let(:fixture_dir) { File.expand_path('../fixtures/codebase_index', __dir__) }
  let(:server) { described_class.build(index_dir: fixture_dir) }

  describe '.build' do
    it 'returns an MCP::Server' do
      expect(server).to be_a(MCP::Server)
    end

    it 'registers 11 tools' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.size).to eq(11)
    end

    it 'registers expected tool names' do
      tools = server.instance_variable_get(:@tools)
      expect(tools.keys).to contain_exactly(
        'lookup', 'search', 'dependencies', 'dependents',
        'structure', 'graph_analysis', 'pagerank', 'framework',
        'recent_changes', 'reload', 'codebase_retrieve'
      )
    end

    it 'registers 2 resources' do
      resources = server.instance_variable_get(:@resources)
      expect(resources.size).to eq(2)
    end

    it 'registers expected resource URIs' do
      resources = server.instance_variable_get(:@resources)
      uris = resources.map(&:uri)
      expect(uris).to contain_exactly('codebase://manifest', 'codebase://graph')
    end

    it 'registers 2 resource templates' do
      templates = server.instance_variable_get(:@resource_templates)
      expect(templates.size).to eq(2)
    end

    it 'registers expected resource template URIs' do
      templates = server.instance_variable_get(:@resource_templates)
      uris = templates.map(&:uri_template)
      expect(uris).to contain_exactly('codebase://unit/{identifier}', 'codebase://type/{type}')
    end
  end

  describe 'tool: lookup' do
    it 'returns unit data for a valid identifier' do
      response = call_tool(server, 'lookup', identifier: 'Post')
      data = parse_response(response)
      expect(data['identifier']).to eq('Post')
      expect(data['type']).to eq('model')
      expect(data['source_code']).to include('has_many')
    end

    it 'returns not found message for invalid identifier' do
      response = call_tool(server, 'lookup', identifier: 'NonExistent')
      expect(response_text(response)).to include('not found')
    end

    it 'excludes source_code when include_source is false' do
      response = call_tool(server, 'lookup', identifier: 'Post', include_source: false)
      data = parse_response(response)
      expect(data['identifier']).to eq('Post')
      expect(data).not_to have_key('source_code')
      expect(data['metadata']).to be_a(Hash)
    end

    it 'returns only selected sections plus always-included keys' do
      response = call_tool(server, 'lookup', identifier: 'Post', sections: ['metadata'])
      data = parse_response(response)
      expect(data.keys).to contain_exactly('type', 'identifier', 'file_path', 'namespace', 'metadata')
    end

    it 'returns full data by default for backward compatibility' do
      response = call_tool(server, 'lookup', identifier: 'Post')
      data = parse_response(response)
      expect(data).to have_key('source_code')
      expect(data).to have_key('metadata')
      expect(data).to have_key('dependencies')
    end

    it 'treats empty sections array as no filtering' do
      response = call_tool(server, 'lookup', identifier: 'Post', sections: [])
      data = parse_response(response)
      expect(data).to have_key('source_code')
      expect(data).to have_key('metadata')
      expect(data).to have_key('dependencies')
    end
  end

  describe 'tool: search' do
    it 'returns matching results' do
      response = call_tool(server, 'search', query: 'Post')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('Post')
    end

    it 'filters by type' do
      response = call_tool(server, 'search', query: 'Post', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end

    it 'respects limit' do
      response = call_tool(server, 'search', query: '.*', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end
  end

  describe 'tool: dependencies' do
    it 'returns forward dependencies' do
      response = call_tool(server, 'dependencies', identifier: 'Comment')
      data = parse_response(response)
      expect(data['root']).to eq('Comment')
      expect(data['nodes']['Comment']['deps']).to include('Post')
    end

    it 'returns empty for unknown identifier' do
      response = call_tool(server, 'dependencies', identifier: 'NonExistent')
      data = parse_response(response)
      expect(data['nodes']).to be_empty
      expect(data['found']).to be false
    end

    it 'includes message for unknown identifier' do
      response = call_tool(server, 'dependencies', identifier: 'NonExistent')
      data = parse_response(response)
      expect(data['found']).to be false
      expect(data['message']).to include('not found in the index')
    end
  end

  describe 'tool: dependents' do
    it 'returns reverse dependencies' do
      response = call_tool(server, 'dependents', identifier: 'Post')
      data = parse_response(response)
      expect(data['root']).to eq('Post')
      expect(data['nodes']['Post']['deps']).to include('Comment', 'PostsController')
    end

    it 'returns found: true with no message for known identifier' do
      response = call_tool(server, 'dependents', identifier: 'Post')
      data = parse_response(response)
      expect(data['found']).to be true
      expect(data).not_to have_key('message')
    end
  end

  describe 'tool: structure' do
    it 'returns manifest by default' do
      response = call_tool(server, 'structure')
      data = parse_response(response)
      expect(data['manifest']).to include('rails_version' => '8.1.2')
    end

    it 'includes summary when detail is full' do
      response = call_tool(server, 'structure', detail: 'full')
      data = parse_response(response)
      expect(data['summary']).to include('Codebase Index Summary')
    end

    it 'excludes summary when detail is summary' do
      response = call_tool(server, 'structure', detail: 'summary')
      data = parse_response(response)
      expect(data).not_to have_key('summary')
    end
  end

  describe 'tool: graph_analysis' do
    it 'returns all sections by default' do
      response = call_tool(server, 'graph_analysis')
      data = parse_response(response)
      expect(data).to include('orphans', 'dead_ends', 'hubs', 'cycles')
    end

    it 'returns a specific section' do
      response = call_tool(server, 'graph_analysis', analysis: 'orphans')
      data = parse_response(response)
      expect(data).to have_key('orphans')
      expect(data['orphans']).to include('PostsController')
    end

    it 'truncates each section when analysis is all with limit' do
      response = call_tool(server, 'graph_analysis', analysis: 'all', limit: 1)
      data = parse_response(response)
      expect(data['hubs'].size).to eq(1)
      expect(data['hubs_total']).to eq(3)
      expect(data['hubs_truncated']).to be true
      # Sections with 1 or fewer items should not have truncation metadata
      expect(data['orphans'].size).to eq(1)
      expect(data).not_to have_key('orphans_truncated')
    end

    it 'truncates nested dependents in hub entries' do
      response = call_tool(server, 'graph_analysis', analysis: 'hubs', limit: 1)
      data = parse_response(response)
      hub = data['hubs'].first
      expect(hub['identifier']).to eq('Post')
      expect(hub['dependents'].size).to eq(1)
      expect(hub['dependents_truncated']).to be true
      expect(hub['dependents_total']).to eq(2)
    end

    it 'handles negative limit without crashing' do
      response = call_tool(server, 'graph_analysis', analysis: 'all', limit: -1)
      data = parse_response(response)
      expect(data['hubs']).to eq([])
      expect(data).to have_key('stats')
    end
  end

  describe 'tool: pagerank' do
    it 'returns ranked nodes with scores' do
      response = call_tool(server, 'pagerank')
      data = parse_response(response)
      expect(data['total_nodes']).to eq(3)
      expect(data['results']).to be_an(Array)
      expect(data['results'].first).to include('identifier', 'type', 'score')
    end

    it 'respects limit' do
      response = call_tool(server, 'pagerank', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end

    it 'filters by type' do
      response = call_tool(server, 'pagerank', types: ['model'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('model')
      end
    end
  end

  describe 'tool: reload' do
    it 'returns reloaded confirmation with manifest fields' do
      response = call_tool(server, 'reload')
      data = parse_response(response)
      expect(data['reloaded']).to be true
      expect(data).to have_key('extracted_at')
      expect(data).to have_key('total_units')
      expect(data).to have_key('counts')
    end

    it 'picks up changed data after reload' do
      # Read structure before reload
      pre = parse_response(call_tool(server, 'structure'))
      expect(pre['manifest']['total_units']).to eq(5)

      # Modify manifest on disk
      manifest_path = File.join(fixture_dir, 'manifest.json')
      original_content = File.read(manifest_path)
      modified = JSON.parse(original_content).merge('total_units' => 42)

      begin
        File.write(manifest_path, JSON.generate(modified))
        call_tool(server, 'reload')

        # Structure should now reflect the new value
        post = parse_response(call_tool(server, 'structure'))
        expect(post['manifest']['total_units']).to eq(42)
      ensure
        File.write(manifest_path, original_content)
      end
    end
  end

  describe 'tool: framework' do
    it 'returns matching rails_source units by identifier keyword' do
      response = call_tool(server, 'framework', keyword: 'ActiveRecord')
      data = parse_response(response)
      expect(data['keyword']).to eq('ActiveRecord')
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against source_code' do
      response = call_tool(server, 'framework', keyword: 'Persistence')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActiveRecord::Base')
    end

    it 'matches against metadata' do
      response = call_tool(server, 'framework', keyword: 'controller')
      data = parse_response(response)
      identifiers = data['results'].map { |r| r['identifier'] }
      expect(identifiers).to include('ActionController::Base')
    end

    it 'returns empty results for no match' do
      response = call_tool(server, 'framework', keyword: 'zzz_no_match')
      data = parse_response(response)
      expect(data['result_count']).to eq(0)
      expect(data['results']).to be_empty
    end

    it 'respects limit' do
      response = call_tool(server, 'framework', keyword: '.*', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end
  end

  describe 'tool: recent_changes' do
    it 'returns units sorted by last_modified descending' do
      response = call_tool(server, 'recent_changes')
      data = parse_response(response)
      expect(data['result_count']).to be >= 1
      dates = data['results'].map { |r| r['last_modified'] }
      expect(dates).to eq(dates.sort.reverse)
    end

    it 'returns the most recently modified unit first' do
      response = call_tool(server, 'recent_changes')
      data = parse_response(response)
      expect(data['results'].first['identifier']).to eq('Comment')
    end

    it 'respects limit' do
      response = call_tool(server, 'recent_changes', limit: 1)
      data = parse_response(response)
      expect(data['results'].size).to eq(1)
    end

    it 'filters by type' do
      response = call_tool(server, 'recent_changes', types: ['controller'])
      data = parse_response(response)
      data['results'].each do |r|
        expect(r['type']).to eq('controller')
      end
    end
  end

  describe 'tool: codebase_retrieve' do
    context 'without retriever configured' do
      it 'returns a fallback message' do
        response = call_tool(server, 'codebase_retrieve', query: 'How does authentication work?')
        text = response_text(response)
        expect(text).to include('Semantic search is not available')
        expect(text).to include('codebase_search')
      end
    end

    context 'with retriever configured' do
      let(:mock_result) do
        Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget, keyword_init: true).new(
          context: "## User (model)\nclass User < ApplicationRecord\nend",
          sources: [{ identifier: 'User', type: 'model' }],
          classification: nil,
          strategy: :vector,
          tokens_used: 150,
          budget: 8000
        )
      end

      let(:retriever) do
        instance_double('CodebaseIndex::Retriever').tap do |r|
          allow(r).to receive(:retrieve).and_return(mock_result)
        end
      end

      let(:server_with_retriever) do
        described_class.build(index_dir: fixture_dir, retriever: retriever)
      end

      it 'calls the retriever with the query and default budget' do
        call_tool(server_with_retriever, 'codebase_retrieve', query: 'How does the User model work?')
        expect(retriever).to have_received(:retrieve).with('How does the User model work?', budget: 8000)
      end

      it 'passes a custom budget to the retriever' do
        call_tool(server_with_retriever, 'codebase_retrieve', query: 'User model', budget: 4000)
        expect(retriever).to have_received(:retrieve).with('User model', budget: 4000)
      end

      it 'returns the context from the retrieval result' do
        response = call_tool(server_with_retriever, 'codebase_retrieve', query: 'User model')
        text = response_text(response)
        expect(text).to include('User (model)')
        expect(text).to include('ApplicationRecord')
      end
    end
  end

  describe 'resource template: codebase://unit/{identifier}' do
    it 'returns unit data for a valid identifier' do
      contents = read_resource(server, 'codebase://unit/Post')
      data = JSON.parse(contents.first[:text])
      expect(data['identifier']).to eq('Post')
      expect(data['type']).to eq('model')
    end

    it 'returns not found for an invalid identifier' do
      contents = read_resource(server, 'codebase://unit/NonExistent')
      expect(contents.first[:text]).to include('not found')
    end
  end

  describe 'resource template: codebase://type/{type}' do
    it 'returns all units of the given type' do
      contents = read_resource(server, 'codebase://type/model')
      data = JSON.parse(contents.first[:text])
      identifiers = data.map { |u| u['identifier'] }
      expect(identifiers).to contain_exactly('Post', 'Comment')
    end

    it 'returns empty array for unknown type' do
      contents = read_resource(server, 'codebase://type/nonexistent')
      data = JSON.parse(contents.first[:text])
      expect(data).to eq([])
    end
  end

  # ────────────────────────────────────────────────────────────────────
  # Helpers
  # ────────────────────────────────────────────────────────────────────

  # Call a tool on the server by name with the given arguments.
  # MCP stores tools as Hash<String, Class>.
  def call_tool(server, tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  # Extract the text content from a tool response.
  def response_text(response)
    response.content.first[:text]
  end

  # Parse JSON from a tool response.
  def parse_response(response)
    JSON.parse(response_text(response))
  end

  # Call the resources_read_handler on the server.
  def read_resource(server, uri)
    handler = server.instance_variable_get(:@handlers)
    read_handler = handler[MCP::Methods::RESOURCES_READ]
    read_handler.call(uri: uri)
  end
end
