# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods'
require 'woods/mcp/server'

RSpec.describe 'Read-only change impact MCP' do
  around do |example|
    Dir.mktmpdir('impact-mcp') do |root|
      @root = root
      payload = File.join(root, 'payloads', 'gen-1')
      FileUtils.mkdir_p(File.join(payload, 'models'))
      unit = { 'identifier' => 'Example', 'type' => 'model', 'source_code' => 'class Example; end',
               'metadata' => {}, 'dependencies' => [] }
      name = "Example_#{Digest::SHA256.hexdigest('Example')[0, 8]}.json"
      File.write(File.join(payload, 'models', name), JSON.generate(unit))
      File.write(File.join(payload, 'models', '_index.json'), '[{"identifier":"Example"}]')
      File.write(File.join(payload, 'manifest.json'), '{"counts":{"models":1},"total_units":1}')
      File.write(File.join(payload, 'dependency_graph.json'), '{"reverse_via":{},"pagerank":{}}')
      File.write(File.join(root, 'generation.json'), '{"number":1,"token":"one","payload":"payloads/gen-1"}')
      example.run
    end
  end

  def server(**options)
    Woods::MCP::Server.build(index_dir: @root, warmup: false, **options)
  end

  def call(srv, **arguments)
    request = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'change_impact', arguments: arguments } }
    JSON.parse(srv.handle_json(JSON.generate(request))).fetch('result')
  end

  it 'is absent without snapshot wiring and present without consulting an empty wired store' do
    expect(server.tools).not_to have_key('change_impact')
    store = double('empty store')
    expect(store).not_to receive(:find)
    expect(store).not_to receive(:diff)
    result = call(server(snapshot_store: store), from: 'gen:1')
    expect(result['isError']).to be(false)
    expect(result.dig('structuredContent', 'data', 'range', 'to', 'generation')).to eq(1)
  end

  it 'uses the same computed report and renderers for every format without saving' do
    srv = server(snapshot_store: double('snapshots'))
    report = Woods::Impact::Report.compare(@root, from: 'gen:1')
    expect(Woods::Impact::Report).to receive(:compare).with(@root, from: 'gen:1',
                                                                   to: 'now').and_return(report).exactly(3).times
    %w[markdown json mermaid].each do |format|
      result = call(srv, from: 'gen:1', format: format)
      expect(result['isError']).to be(false)
      expect(result.dig('structuredContent', 'data')).to eq(report.to_h)
      text = format == 'json' ? report.to_json : Woods::Impact::Renderers.public_send(format, report)
      expect(result.dig('content', 0, 'text')).to eq(text)
    end
    expect(File.exist?(File.join(@root, 'explorer'))).to be(false)
  end

  it 'computes exact typed focus against one endpoint without a range' do
    result = call(server(snapshot_store: double('snapshots')),
                  focus: [{ identifier: 'Example', type: 'model' }], at: 'gen:1')
    expect(result['isError']).to be(false)
    expect(result.dig('structuredContent', 'data')).to include('range' => nil, 'changed' => [])
    expect(result.dig('structuredContent', 'data', 'focus')).to eq([{ 'identifier' => 'Example', 'type' => 'model' }])
  end

  it 'rejects mixed selectors, missing roots and unavailable retained endpoints explicitly' do
    srv = server(snapshot_store: double('snapshots'))
    [{}, { from: 'gen:1', at: 'now' }, { from: 'gen:1', focus: [] }, { from: 'gen:2' },
     { focus: [{ identifier: 'Missing', type: 'model' }] }].each do |arguments|
      expect(call(srv, **arguments)['isError']).to be(true)
    end
  end

  it 'matches Impact depth and work bounds while keeping traversal depth unchanged' do
    srv = server(snapshot_store: double('snapshots'))
    schema = srv.tools.fetch('change_impact').input_schema_value.to_h
    properties = schema.fetch(:properties)
    expect(properties.fetch(:depth)).to include(minimum: 0, maximum: 10)
    expect(properties.fetch(:max_flow_operations)).to include(minimum: 1, maximum: 100_000)
    expect(properties.fetch(:focus)).to include(maxItems: 1000)
    expect(srv.tools.fetch('dependents').input_schema_value.to_h.dig(:properties, :depth, :maximum)).to eq(20)
    expect(call(srv, from: 'gen:1', depth: 11).dig('_meta', 'error_code')).to eq('invalid_arguments')
    expect(call(srv, from: 'gen:1', max_flow_operations: 0).dig('_meta', 'error_code')).to eq('invalid_arguments')
  end

  it 'reports corrupt required endpoint data as an artifact error rather than an empty report' do
    File.write(File.join(@root, 'payloads', 'gen-1', 'manifest.json'), '{broken')
    result = call(server(snapshot_store: double('snapshots')), from: 'gen:1')
    expect(result['isError']).to be(true)
    expect(result.dig('_meta', 'error_code')).to eq('corrupt_artifact')
    expect(result.dig('structuredContent', 'data')).to be_nil
  end
  it 'keeps non-object manifests in the artifact-error contract for generation and SHA selectors' do
    %w[[] null].each do |manifest|
      File.write(File.join(@root, 'payloads', 'gen-1', 'manifest.json'), manifest)
      %w[gen:1 abcdef1].each do |selector|
        result = call(server(snapshot_store: double('snapshots')), from: selector)
        expect(result['isError']).to be(true)
        expect(result.dig('_meta', 'error_code')).to eq('corrupt_artifact')
      end
    end
  end
end
