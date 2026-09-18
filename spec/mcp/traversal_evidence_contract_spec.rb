# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Traversal explanation contract' do
  let(:directory) { Dir.mktmpdir('woods-traversal-contract') }
  let(:reader) { Woods::MCP::IndexReader.new(directory) }

  before do
    Woods.configuration = Woods::Configuration.new
    FileUtils.cp_r(File.join(File.expand_path('../fixtures/woods', __dir__), '.'), directory)
  end
  after { FileUtils.remove_entry(directory) }

  def call_tool(name = 'dependencies', format: :json, **arguments)
    server = Woods::MCP::Server.build(index_dir: directory, response_format: format, warmup: false)
    meta = {
      'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
      'io.modelcontextprotocol/clientInfo' => { name: 'traversal-contract', version: '1' },
      'io.modelcontextprotocol/clientCapabilities' => {}
    }
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                params: { name: name, arguments: arguments, _meta: meta } }
    JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
  end

  %w[dependencies dependents].each do |name|
    it "preserves #{name} compact defaults and rejects nonboolean explain arguments" do
      root = name == 'dependencies' ? 'Comment' : 'Post'
      compact = call_tool(name, identifier: root)
      expect(call_tool(name, identifier: root, explain: false)).to eq(compact)
      expect(compact.dig('structuredContent', 'data')).not_to have_key('explanation')
      invalid = call_tool(name, identifier: root, explain: 'yes')
      expect(invalid['isError']).to be(true)
      expect(invalid.dig('_meta', 'error_code')).to eq('invalid_arguments')
    end
  end

  it 'returns directed typed evidence and unknown legacy labels through the actual MCP wire' do
    result = call_tool('dependents', identifier: 'Post', explain: true)
    expect(result['isError']).to be(false)
    explanation = result.dig('structuredContent', 'data', 'explanation')
    expect(explanation['direction']).to eq('reverse')
    expect(explanation['edges'].values.first).to include(
      'source' => { 'identifier' => 'Comment', 'type' => 'model' },
      'target' => { 'identifier' => 'Post', 'type' => 'model' }, 'via' => nil, 'disable_joins' => nil
    )
  end

  it 'keeps a later page self-contained through explicitly marked ancestor context' do
    result = call_tool(identifier: 'Comment', explain: true, limit: 1, offset: 1)
    data = result.dig('structuredContent', 'data')
    expect(data['nodes'].keys).to eq(['Post'])
    expect(data).to include('nodes_total' => 2, 'nodes_offset' => 1)
    expect(data['explanation']['witnesses']['Comment']).to include('context' => true, 'impact' => 'root')
    expect(data['explanation']['witnesses']['Post']).to include('context' => false, 'parent' => 'Comment')
  end

  %i[markdown plain claude].each do |format|
    it "renders typed ambiguity, transitive uncertainty and recorded false attributes in #{format}" do
      path = File.join(directory, 'dependency_graph.json')
      graph = JSON.parse(File.read(path))
      graph['variants'] = [{ 'identifier' => 'Post', 'type' => 'service', 'edges' => [] }]
      graph['edges']['Comment'] = [{ 'target' => 'Post', 'via' => 'has_many', 'through' => 'subscriptions',
                                     'through_db' => 'reporting', 'disable_joins' => false }]
      graph['edges']['Post'] = [{ 'target' => 'Outside', 'via' => 'calls' }]
      graph['reverse']['Outside'] = ['Post']
      File.write(path, JSON.generate(graph))
      text = call_tool(format: format, identifier: 'Comment', explain: true).dig('structuredContent', 'text')
      expect(text).to include('Post (ambiguous; candidate types: model, service)',
                              'Outside (unresolved; candidate types: none)',
                              'via=has_many; through=subscriptions; through_db=reporting; disable_joins=false',
                              'Outside: transitive; parent=Post;', 'witness types unambiguous=no')
    end

    it "renders the same directed edges, unknowns, witnesses and context in #{format}" do
      result = call_tool(format: format, identifier: 'Comment', explain: true, limit: 1, offset: 1)
      text = result.dig('structuredContent', 'text')
      expect(text).to include('Comment (model) -> Post (model)', 'via=unknown', 'disable_joins=unknown',
                              'Post: direct; parent=Comment; edge=e0; witness types unambiguous=yes; context only=no',
                              'Comment: root; parent=none; edge=none; witness types unambiguous=yes; context only=yes',
                              'transitive = inferred reachability, not observed execution')
    end
  end

  it 'preserves budget metadata after an empty page and does not leave unrelated evidence' do
    result = call_tool(identifier: 'Comment', explain: true, max_nodes: 1, offset: 3)
    data = result.dig('structuredContent', 'data')
    expect(data).to include('partial' => true, 'partial_reason' => 'node_budget')
    expect(data['explanation']).to include('edges' => {}, 'witnesses' => {})
  end

  it 'does not build the optional evidence index for compact mode and caches it until reload' do
    expect(Woods::MCP::TraversalEvidenceIndex).not_to receive(:new)
    reader.traverse_dependencies('Comment')
    RSpec::Mocks.space.proxy_for(Woods::MCP::TraversalEvidenceIndex).reset
    expect(Woods::MCP::TraversalEvidenceIndex).to receive(:new).twice.and_call_original
    2.times { reader.traverse_dependencies('Comment', explain: true) }
    reader.reload!
    reader.traverse_dependencies('Comment', explain: true)
  end

  def publish_graph(number, via)
    payload = File.join(directory, 'payloads', "gen-#{number}")
    FileUtils.mkdir_p(payload)
    source = File.expand_path('../fixtures/woods', __dir__)
    FileUtils.cp_r(File.join(source, '.'), payload)
    path = File.join(payload, 'dependency_graph.json')
    graph = JSON.parse(File.read(path))
    graph['edges']['Comment'] = [{ 'target' => 'Post', 'via' => via }]
    File.write(path, JSON.generate(graph))
    Woods::Generation.new(output_dir: directory).bump!(payload: "payloads/gen-#{number}")
  end

  it 'retains one generation during evidence construction and adopts the next publication afterwards' do
    publish_graph(1, 'before')
    allow(Woods::MCP::TraversalEvidenceIndex).to receive(:new).and_wrap_original do |original, graph|
      publish_graph(2, 'after') unless reader.loaded_generation == 2
      original.call(graph)
    end
    first = reader.traverse_dependencies('Comment', explain: true)
    expect(first[:explanation][:edges].values.first[:via]).to eq('before')
    second = reader.traverse_dependencies('Comment', explain: true)
    expect(second[:explanation][:edges].values.first[:via]).to eq('after')
  end
end
