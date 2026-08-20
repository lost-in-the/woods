# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Index MCP corrupt artifact errors' do
  let(:fixture_dir) { File.expand_path('../fixtures/woods', __dir__) }
  let(:tmpdir) { Dir.mktmpdir('woods-tool-corrupt') }
  let(:index_dir) { File.join(tmpdir, 'index') }

  after { FileUtils.rm_rf(tmpdir) }

  def corrupt_cases
    {
      'lookup' => ['models/Post_a5554622.json', { 'identifier' => 'Post' }],
      'search' => ['models/_index.json', { 'query' => 'Post' }],
      'dependencies' => ['dependency_graph.json', { 'identifier' => 'Comment' }],
      'dependents' => ['dependency_graph.json', { 'identifier' => 'Post' }],
      'structure' => ['manifest.json', {}],
      'graph_analysis' => ['graph_analysis.json', {}],
      'domain_clusters' => ['dependency_graph.json', {}],
      'pagerank' => ['dependency_graph.json', {}],
      'framework' => ['rails_source/_index.json', { 'keyword' => 'ActiveRecord' }],
      'recent_changes' => ['models/Post_a5554622.json', { 'types' => ['model'] }],
      'trace_flow' => ['dependency_graph.json', { 'entry_point' => 'PostsController#create' }]
    }
  end

  def call_tool(server, name, arguments)
    params = {
      name: name,
      arguments: arguments,
      _meta: {
        'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
        'io.modelcontextprotocol/clientInfo' => { 'name' => 'corrupt-spec', 'version' => '1.0' },
        'io.modelcontextprotocol/clientCapabilities' => {}
      }
    }
    raw = server.handle_json(JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: params))
    JSON.parse(raw)
  end

  it 'returns stable metadata from every Index-backed tool when its artifact is corrupt' do
    aggregate_failures do
      corrupt_cases.each do |tool, (relative_path, arguments)|
        FileUtils.rm_rf(index_dir)
        FileUtils.mkdir_p(index_dir)
        FileUtils.cp_r(File.join(fixture_dir, '.'), index_dir)
        File.binwrite(File.join(index_dir, relative_path), '{not-json')
        server = Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false)

        result = call_tool(server, tool, arguments).fetch('result')

        expect(result['isError']).to be(true), tool
        expect(result.dig('_meta', 'error_code')).to eq('corrupt_artifact'), tool
        expect(result.dig('_meta', 'tool')).to eq(tool), tool
      end
    end
  end

  it 'keeps woods_status available as a degraded diagnostic when the manifest is corrupt' do
    FileUtils.mkdir_p(index_dir)
    FileUtils.cp_r(File.join(fixture_dir, '.'), index_dir)
    File.binwrite(File.join(index_dir, 'manifest.json'), '{not-json')
    server = Woods::MCP::Server.build(index_dir: index_dir, response_format: :json, warmup: false)

    result = call_tool(server, 'woods_status', {}).fetch('result')
    payload = result.dig('structuredContent', 'data')

    expect(result['isError']).to be(false)
    expect(payload['ready']).to be_falsey
    expect(payload.dig('index', 'counts')).to eq({})
  end
end
