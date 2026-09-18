# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/mcp/server'
require 'woods/session_tracer/file_store'
require 'woods/session_tracer/session_flow_assembler'

RSpec.describe 'Session context identity' do
  let(:directory) { Dir.mktmpdir('woods-session-identity') }
  let(:index) { File.join(directory, 'index') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:reader) { Woods::MCP::IndexReader.new(index) }
  let(:store) { Woods::SessionTracer::FileStore.new(base_dir: File.join(directory, 'sessions')) }
  let(:assembler) { Woods::SessionTracer::SessionFlowAssembler.new(store: store, reader: reader) }
  let(:ambiguity) { Woods::SessionTracer::AmbiguousUnitError }

  before do
    @entries = Hash.new { |hash, key| hash[key] = [] }
    write_unit('FirstController', 'controller', ['Shared'])
    write_unit('Shared', 'service')
    write_unit('Shared', 'poro')
    publish
    record('FirstController')
  end

  after { FileUtils.remove_entry(directory) }

  def write_unit(identifier, type, dependencies = [])
    dir = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }.first
    FileUtils.mkdir_p(File.join(index, dir))
    unit = Woods::ExtractedUnit.new(type: type.to_sym, identifier: identifier, file_path: "app/#{dir}/#{identifier}.rb")
    unit.source_code = "#{type}-secret-source"
    unit.dependencies = dependencies.map { |target| { target: target, via: :code_reference } }
    graph.register(unit)
    File.write(unit_path(identifier, dir), JSON.generate(unit.to_h))
    # Legacy summaries have no type field; identity must come from the bucket/body.
    @entries[dir] |= [{ identifier: identifier }]
    File.write(File.join(index, dir, '_index.json'), JSON.generate(@entries[dir]))
  end

  def unit_path(identifier, dir)
    File.join(index, dir, "#{identifier}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json")
  end

  def publish
    File.write(File.join(index, 'dependency_graph.json'), JSON.generate(graph.to_h))
    File.write(File.join(index, 'manifest.json'), JSON.generate(counts: @entries.transform_values(&:size)))
  end

  def record(controller)
    store.record('trace', { 'controller' => controller, 'action' => 'index', 'method' => 'GET', 'path' => '/' })
  end

  it 'rejects ambiguous direct targets with deterministic concrete types' do
    expect { assembler.assemble('trace') }.to raise_error(ambiguity) do |error|
      expect(error.identifier).to eq('Shared')
      expect(error.types).to eq(%w[poro service])
      expect(error.message).to include('depth: 0', 'lookup')
    end
  end

  it 'rejects the collision even when a typed controller has already filled the pool' do
    write_unit('Shared', 'controller')
    publish
    store.clear('trace')
    record('Shared')
    record('FirstController')
    expect { assembler.assemble('trace') }.to raise_error(ambiguity)
  end

  [%w[FirstController Shared], %w[Shared FirstController]].each do |controllers|
    it "does not alias a missing controller to a dependency for request order #{controllers.join(', ')}" do
      FileUtils.remove_entry(File.join(index, 'services'))
      @entries.delete('services')
      graph.unregister('Shared', type: :service)
      publish
      store.clear('trace')
      controllers.each { |controller| record(controller) }

      document = assembler.assemble('trace')
      missing_step = document.steps.find { |step| step[:controller] == 'Shared' }
      expect(missing_step).to include(controller: 'Shared', action: 'index', unit_refs: [])
      expect(document.context_pool.fetch('Shared')[:type]).to eq('poro')
      expect(document.steps.find { |step| step[:controller] == 'FirstController' }[:unit_refs]).to include('Shared')
    end
  end

  it 'does not classify an ambiguous job name as an async side effect' do
    write_unit('Shared', 'job')
    publish
    expect { assembler.assemble('trace') }.to raise_error(ambiguity) do |error|
      expect(error.types).to eq(%w[job poro service])
    end
  end

  it 'checks transitive targets only at the requested expansion depth' do
    write_unit('FirstController', 'controller', ['Bridge'])
    write_unit('Bridge', 'service', ['Shared'])
    publish
    expect(assembler.assemble('trace', depth: 1).context_pool.keys).to eq(%w[FirstController Bridge])
    expect { assembler.assemble('trace', depth: 2) }.to raise_error(ambiguity)
  end

  it 'finds concrete shared-bucket types even when summaries omit their type' do
    write_unit('Shared', 'graphql_mutation')
    write_unit('Shared', 'gem_source')
    publish
    expect { assembler.assemble('trace') }.to raise_error(ambiguity) do |error|
      expect(error.types).to eq(%w[gem_source graphql_mutation poro service])
    end
  end

  it 'keeps metadata-only timelines available without dependency resolution' do
    document = assembler.assemble('trace', depth: 0)
    expect(document.steps.size).to eq(1)
    expect(document.context_pool).to be_empty
    expect(document.dependency_map).to be_empty
  end

  it 'does not read unrelated unit bodies when checking candidates' do
    write_unit('FirstController', 'controller', ['Unique'])
    write_unit('Unique', 'service')
    publish
    File.write(unit_path('Shared', 'poros'), 'broken unrelated body')
    expect(assembler.assemble('trace').context_pool.keys).to eq(%w[FirstController Unique])
  end

  it 'refuses a missing listed sibling rather than choosing the surviving type' do
    File.unlink(unit_path('Shared', 'poros'))
    expect { assembler.assemble('trace') }.to raise_error(Errno::ENOENT)
  end

  it 'refuses a corrupt listed sibling rather than choosing the surviving type' do
    File.write(unit_path('Shared', 'poros'), '{broken')
    expect { assembler.assemble('trace') }.to raise_error(JSON::ParserError)
  end

  it 'refuses a sibling whose body claims a different typed identity' do
    path = unit_path('Shared', 'poros')
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge('type' => 'service')))
    expect { assembler.assemble('trace') }.to raise_error(IOError, /typed unit identity mismatch/)
  end

  it 'does not treat a missing sibling summary as proof of unique identity' do
    File.unlink(File.join(index, 'poros', '_index.json'))
    expect { assembler.assemble('trace') }.to raise_error(IOError, /unit count mismatch in poros/)
  end

  it 'holds one generation across candidate discovery, body reads and concurrent reload' do
    # Generation 1 is unambiguous; generation 2 adds the same-name PORO.
    old_payload = File.join(index, 'payloads', 'gen-1')
    new_payload = File.join(index, 'payloads', 'gen-2')
    FileUtils.mkdir_p(File.dirname(old_payload))
    FileUtils.mkdir_p(new_payload)
    FileUtils.cp_r(Dir.glob(File.join(index, '*')).reject { |path| path.end_with?('/payloads') }, new_payload)
    FileUtils.cp_r(new_payload, old_payload)
    FileUtils.remove_entry(File.join(old_payload, 'poros'))
    old_graph = Woods::DependencyGraph.from_h(graph.to_h)
    old_graph.unregister('Shared', type: :poro)
    File.write(File.join(old_payload, 'dependency_graph.json'), JSON.generate(old_graph.to_h))
    manifest_path = File.join(old_payload, 'manifest.json')
    data = JSON.parse(File.read(manifest_path))
    data['counts'].delete('poros')
    File.write(manifest_path, JSON.generate(data))
    marker = Woods::Generation.new(output_dir: index)
    marker.bump!(reason: 'test', payload: 'payloads/gen-1')
    reloaded = Queue.new
    original = reader.method(:list_units)
    reload_thread = nil
    reader.define_singleton_method(:list_units) do |**options|
      entries = original.call(**options)
      unless reload_thread
        marker.bump!(reason: 'test', payload: 'payloads/gen-2')
        reload_thread = Thread.new { with_exclusive_reload { reloaded << true } }
        Timeout.timeout(5) { Thread.pass until instance_variable_get(:@exclusive_waiters).positive? }
        raise 'reload completed during session assembly' unless reloaded.empty?
      end
      entries
    end

    expect(assembler.assemble('trace').context_pool.fetch('Shared')[:type]).to eq('service')
    wait_for_thread_signal(reloaded, timeout: 5, reload: reload_thread)
    expect(reload_thread.join(5)).to eq(reload_thread)
    expect(reader.loaded_generation).to eq(2)
    expect { assembler.assemble('trace') }.to raise_error(ambiguity)
  ensure
    reload_thread&.kill&.join(1)
  end

  it 'keeps missing candidate artifacts at the real MCP internal-error boundary' do
    File.unlink(unit_path('Shared', 'poros'))
    Woods.configuration.session_store = store
    server = Woods::MCP::Server.build(index_dir: index, response_format: :json, warmup: false)
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                            params: { name: 'session_trace', arguments: { session_id: 'trace' } })
    response = JSON.parse(server.handle_json(request)).fetch('result')
    expect(response['isError']).to be(true)
    expect(response['_meta']).to include('error_code' => 'internal_error')
    text = response.fetch('content').first.fetch('text')
    expect(text).to include('Session trace failed')
    expect(text).not_to include('secret-source', '## Session:', 'Ambiguous session unit')
  ensure
    Woods.configuration.session_store = nil
  end

  it 'returns a real MCP tool error with no partial session source' do
    Woods.configuration.session_store = store
    server = Woods::MCP::Server.build(index_dir: index, response_format: :json, warmup: false)
    request = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call',
                            params: { name: 'session_trace', arguments: { session_id: 'trace' } })
    response = JSON.parse(server.handle_json(request)).fetch('result')
    expect(response['isError']).to be(true)
    expect(response['_meta']).to include('error_code' => 'ambiguous_identity', 'identifier' => 'Shared',
                                         'types' => %w[poro service])
    text = response.fetch('content').first.fetch('text')
    expect(text).to include('Ambiguous session unit')
    expect(text).not_to include('secret-source', '## Session:')
  ensure
    Woods.configuration.session_store = nil
  end
end
