# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'woods'
require 'woods/mcp/index_reader'
require 'woods/session_tracer/file_store'
require 'woods/session_tracer/session_flow_assembler'

RSpec.describe 'Readers with an already known unit type (#213)' do
  let(:directory) { Dir.mktmpdir('woods-known-type-readers') }
  let(:index) { File.join(directory, 'index') }
  let(:graph) { Woods::DependencyGraph.new }
  let(:reader) { Woods::MCP::IndexReader.new(index) }
  let(:store) { Woods::SessionTracer::FileStore.new(base_dir: File.join(directory, 'sessions')) }

  before do
    @entries = Hash.new { |hash, key| hash[key] = [] }
    write_unit('SharedController', 'controller', 'controller-marker', '2026-01-01', ['ExpectedService'])
    write_unit('SharedController', 'rails_source', 'framework-marker', '2026-02-01')
    write_unit('SharedController', 'poro', 'unrelated-marker', '2026-03-01', ['OtherService'])
    write_unit('ExpectedService', 'service', 'expected-service', '2026-01-01')
    write_unit('OtherService', 'service', 'other-service', '2026-01-01')
    File.write(File.join(index, 'dependency_graph.json'), JSON.generate(graph.to_h))
    File.write(File.join(index, 'manifest.json'), JSON.generate(counts: @entries.transform_values(&:size)))
    store.record('trace', { 'controller' => 'SharedController', 'action' => 'index', 'method' => 'GET', 'path' => '/' })
  end

  after { FileUtils.remove_entry(directory) }

  def write_unit(identifier, type, source, date, dependencies = [])
    dir = Woods::MCP::IndexReader::UNIT_TYPES_BY_DIR.find { |_, types| types.include?(type) }.first
    path = File.join(index, dir)
    FileUtils.mkdir_p(path)
    unit = Woods::ExtractedUnit.new(type: type.to_sym, identifier: identifier,
                                    file_path: "app/#{dir}/#{identifier}.rb")
    unit.source_code = source
    unit.metadata = { git: { last_modified: date, last_author: type } }
    unit.dependencies = dependencies.map { |target| { target: target, via: :code_reference } }
    graph.register(unit)
    filename = "#{identifier}_#{Digest::SHA256.hexdigest(identifier)[0, 8]}.json"
    File.write(File.join(path, filename), JSON.generate(unit.to_h))
    write_index_entry(dir, unit)
  end

  def write_index_entry(dir, unit)
    @entries[dir] << { identifier: unit.identifier, type: unit.type, file_path: unit.file_path }
    File.write(File.join(index, dir, '_index.json'), JSON.generate(@entries[dir]))
  end

  it 'matches framework source and metadata from its own bucket when names collide' do
    expect(reader.framework_sources('framework-marker')).to contain_exactly(
      include(identifier: 'SharedController', type: 'rails_source', file_path: 'app/rails_source/SharedController.rb')
    )
    expect(reader.framework_sources('unrelated-marker')).to be_empty
  end

  it 'keeps recent-change paths, dates and authors within the selected type' do
    expected = [
      { identifier: 'SharedController', type: 'controller', file_path: 'app/controllers/SharedController.rb',
        last_modified: '2026-01-01', author: 'controller' }
    ]
    expect(reader.recent_changes(types: ['controller'])).to eq(expected)
  end

  it 'returns each selected typed record rather than repeating one colliding unit' do
    rows = reader.recent_changes(types: %w[controller poro])
    expected = [
      ['poro', 'app/poros/SharedController.rb', '2026-03-01'],
      ['controller', 'app/controllers/SharedController.rb', '2026-01-01']
    ]
    expect(rows.map { |row| [row[:type], row[:file_path], row[:last_modified]] }).to eq(expected)
  end

  it 'retains gem-source records in the shared framework bucket' do
    write_unit('GemApi', 'gem_source', 'gem-marker', '2026-04-01')
    write_unit('GemApi', 'poro', 'not-a-gem', '2026-05-01')
    expect(reader.framework_sources('gem-marker')).to contain_exactly(
      include(identifier: 'GemApi', file_path: 'app/rails_source/GemApi.rb',
              metadata: { 'git' => { 'last_modified' => '2026-04-01', 'last_author' => 'gem_source' } })
    )
  end

  it 'retains concrete GraphQL records in the shared GraphQL bucket' do
    write_unit('CreateInvoice', 'graphql_mutation', 'mutation-marker', '2026-04-01')
    write_unit('CreateInvoice', 'poro', 'not-a-mutation', '2026-05-01')
    expect(reader.recent_changes(types: ['graphql'])).to contain_exactly(
      include(identifier: 'CreateInvoice', file_path: 'app/graphql/CreateInvoice.rb',
              last_modified: '2026-04-01', author: 'graphql_mutation')
    )
  end

  it 'resolves the session controller and only that controller variant’s outgoing edges' do
    document = Woods::SessionTracer::SessionFlowAssembler.new(store: store, reader: reader).assemble('trace', depth: 1)
    expect(document.context_pool.fetch('SharedController')).to include(type: 'controller',
                                                                       source_code: 'controller-marker')
    expect(document.context_pool.keys).to contain_exactly('SharedController', 'ExpectedService')
    expect(document.dependency_map.fetch('SharedController')).to eq(['ExpectedService'])
  end

  it 'does not substitute a different type when the captured controller is absent' do
    FileUtils.remove_entry(File.join(index, 'controllers'))
    @entries.delete('controllers')
    graph.unregister('SharedController', type: :controller)
    File.write(File.join(index, 'dependency_graph.json'), JSON.generate(graph.to_h))
    File.write(File.join(index, 'manifest.json'), JSON.generate(counts: @entries.transform_values(&:size)))
    document = Woods::SessionTracer::SessionFlowAssembler.new(store: store, reader: reader).assemble('trace', depth: 1)
    expect(document.context_pool).to be_empty
    expect(document.dependency_map).to be_empty
  end
end
