# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'codebase_index/session_tracer/session_flow_assembler'
require 'codebase_index/session_tracer/file_store'
require 'codebase_index/mcp/index_reader'
require 'codebase_index/dependency_graph'

RSpec.describe CodebaseIndex::SessionTracer::SessionFlowAssembler do
  let(:base_dir) { Dir.mktmpdir('session_assembler_store') }
  let(:index_dir) { Dir.mktmpdir('session_assembler_index') }
  let(:store) { CodebaseIndex::SessionTracer::FileStore.new(base_dir: base_dir) }
  let(:graph) { CodebaseIndex::DependencyGraph.new }

  after do
    FileUtils.remove_entry(base_dir)
    FileUtils.remove_entry(index_dir)
  end

  # Helper to write unit JSON into the index directory structure
  def write_index_unit(identifier, type:, source_code:, dependencies: [])
    type_dir = CodebaseIndex::MCP::IndexReader::TYPE_TO_DIR[type]
    dir = File.join(index_dir, type_dir)
    FileUtils.mkdir_p(dir)

    data = {
      'type' => type,
      'identifier' => identifier,
      'file_path' => "app/#{type_dir}/#{identifier.gsub('::', '/').downcase}.rb",
      'source_code' => source_code,
      'metadata' => {},
      'dependencies' => dependencies.map { |d| { 'target' => d } }
    }

    filename = "#{identifier.gsub('::', '__')}.json"
    File.write(File.join(dir, filename), JSON.generate(data))
    data
  end

  # Helper to write _index.json files
  def write_index_files(units_by_type)
    units_by_type.each do |type, identifiers|
      type_dir = CodebaseIndex::MCP::IndexReader::TYPE_TO_DIR[type]
      dir = File.join(index_dir, type_dir)
      FileUtils.mkdir_p(dir)

      index_data = identifiers.map { |id| { 'identifier' => id, 'chunk_count' => 1 } }
      File.write(File.join(dir, '_index.json'), JSON.generate(index_data))
    end
  end

  # Helper to write manifest.json
  def write_manifest(counts = {})
    File.write(
      File.join(index_dir, 'manifest.json'),
      JSON.generate({
                      'extracted_at' => '2026-02-13T10:00:00Z',
                      'counts' => counts,
                      'total_units' => counts.values.sum
                    })
    )
  end

  # Helper to write dependency graph
  def write_graph(graph)
    File.write(
      File.join(index_dir, 'dependency_graph.json'),
      JSON.generate(graph.to_h)
    )
  end

  # Helper to record a request to the store
  def record_request(session_id, controller:, action:, method: 'GET', path: '/', status: 200)
    store.record(session_id, {
                   'session_id' => session_id,
                   'timestamp' => Time.now.utc.iso8601,
                   'method' => method,
                   'path' => path,
                   'controller' => controller,
                   'action' => action,
                   'status' => status,
                   'duration_ms' => 42,
                   'format' => 'html'
                 })
  end

  # Set up a basic index with Orders and Posts
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def setup_basic_index
    controller_src = "class OrdersController < ApplicationController\n  def index; end\n  def create; end\nend"
    write_index_unit('OrdersController', type: 'controller',
                                         source_code: controller_src,
                                         dependencies: %w[Order OrderPolicy])
    write_index_unit('Order', type: 'model',
                              source_code: "class Order < ApplicationRecord\n  belongs_to :user\nend",
                              dependencies: %w[User])
    write_index_unit('OrderPolicy', type: 'service',
                                    source_code: "class OrderPolicy\n  def allowed?; end\nend")
    write_index_unit('User', type: 'model',
                             source_code: "class User < ApplicationRecord\nend")
    write_index_unit('SyncOrderJob', type: 'job',
                                     source_code: "class SyncOrderJob < ApplicationJob\n  def perform; end\nend")

    write_index_files(
      'controller' => ['OrdersController'],
      'model' => %w[Order User],
      'service' => ['OrderPolicy'],
      'job' => ['SyncOrderJob']
    )
    write_manifest('controllers' => 1, 'models' => 2, 'services' => 1, 'jobs' => 1)

    # Register units in graph
    unit_struct = Struct.new(:identifier, :type, :file_path, :namespace, :dependencies, keyword_init: true)
    orders_deps = [{ target: 'Order' }, { target: 'OrderPolicy' }, { target: 'SyncOrderJob' }]
    graph.register(unit_struct.new(identifier: 'OrdersController', type: :controller, file_path: 'a', namespace: nil,
                                   dependencies: orders_deps))
    graph.register(unit_struct.new(identifier: 'Order', type: :model, file_path: 'b', namespace: nil,
                                   dependencies: [{ target: 'User' }]))
    graph.register(unit_struct.new(identifier: 'OrderPolicy', type: :service, file_path: 'c', namespace: nil,
                                   dependencies: []))
    graph.register(unit_struct.new(identifier: 'User', type: :model, file_path: 'd', namespace: nil, dependencies: []))
    graph.register(unit_struct.new(identifier: 'SyncOrderJob', type: :job, file_path: 'e', namespace: nil,
                                   dependencies: []))

    write_graph(graph)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  describe '#assemble' do
    before { setup_basic_index }

    let(:reader) { CodebaseIndex::MCP::IndexReader.new(index_dir) }
    let(:assembler) { described_class.new(store: store, reader: reader) }

    it 'produces a SessionFlowDocument' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1')

      expect(doc).to be_a(CodebaseIndex::SessionTracer::SessionFlowDocument)
      expect(doc.session_id).to eq('sess1')
    end

    it 'builds timeline steps from requests' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')
      record_request('sess1', controller: 'OrdersController', action: 'create',
                              method: 'POST', path: '/orders', status: 302)

      doc = assembler.assemble('sess1')

      expect(doc.steps.size).to eq(2)
      expect(doc.steps[0][:action]).to eq('index')
      expect(doc.steps[1][:action]).to eq('create')
      expect(doc.steps[1][:status]).to eq(302)
    end

    it 'resolves controller units into context pool' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1')

      expect(doc.context_pool).to have_key('OrdersController')
      expect(doc.context_pool['OrdersController'][:type]).to eq('controller')
    end

    it 'deduplicates units across multiple requests' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')
      record_request('sess1', controller: 'OrdersController', action: 'create',
                              method: 'POST', path: '/orders')

      doc = assembler.assemble('sess1')

      # Controller should appear only once in context pool
      controller_entries = doc.context_pool.select { |_, v| v[:type] == 'controller' }
      expect(controller_entries.size).to eq(1)
    end

    it 'expands direct dependencies at depth 1' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1', depth: 1)

      expect(doc.context_pool).to have_key('Order')
      expect(doc.context_pool).to have_key('OrderPolicy')
    end

    it 'separates jobs as async side effects' do
      record_request('sess1', controller: 'OrdersController', action: 'create',
                              method: 'POST', path: '/orders')

      doc = assembler.assemble('sess1', depth: 1)

      job_effects = doc.side_effects.select { |e| e[:type] == :job }
      expect(job_effects.size).to eq(1)
      expect(job_effects[0][:identifier]).to eq('SyncOrderJob')

      # Jobs should NOT be in context pool
      expect(doc.context_pool).not_to have_key('SyncOrderJob')
    end

    it 'builds a dependency map' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1', depth: 1)

      expect(doc.dependency_map).to have_key('OrdersController')
      expect(doc.dependency_map['OrdersController']).to include('Order')
    end

    it 'returns metadata-only at depth 0' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1', depth: 0)

      expect(doc.steps.size).to eq(1)
      expect(doc.context_pool).to be_empty
      expect(doc.side_effects).to be_empty
    end

    it 'expands transitive dependencies at depth 2' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1', depth: 2)

      # Order depends on User, should be expanded at depth 2
      expect(doc.context_pool).to have_key('User')
    end

    it 'returns empty document for unknown session' do
      doc = assembler.assemble('nonexistent')

      expect(doc.steps).to be_empty
      expect(doc.context_pool).to be_empty
    end

    it 'handles requests for controllers not in the index' do
      record_request('sess1', controller: 'UnknownController', action: 'index', path: '/unknown')

      doc = assembler.assemble('sess1')

      expect(doc.steps.size).to eq(1)
      expect(doc.context_pool).to be_empty
    end

    it 'estimates token count' do
      record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

      doc = assembler.assemble('sess1', depth: 1)

      expect(doc.token_count).to be > 0
    end

    describe 'token budget' do
      it 'truncates source when over budget' do
        record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

        # Very small budget
        doc = assembler.assemble('sess1', budget: 50, depth: 1)

        truncated = doc.context_pool.values.select { |u| u[:source_code]&.start_with?('# source truncated') }
        expect(truncated).not_to be_empty
      end

      it 'does not truncate when under budget' do
        record_request('sess1', controller: 'OrdersController', action: 'index', path: '/orders')

        doc = assembler.assemble('sess1', budget: 100_000, depth: 1)

        truncated = doc.context_pool.values.select { |u| u[:source_code]&.start_with?('# source truncated') }
        expect(truncated).to be_empty
      end
    end

    describe 'output formats' do
      before do
        record_request('sess1', controller: 'OrdersController', action: 'create',
                                method: 'POST', path: '/orders', status: 302)
      end

      it 'produces valid markdown' do
        doc = assembler.assemble('sess1', depth: 1)
        md = doc.to_markdown

        expect(md).to include('## Session: sess1')
        expect(md).to include('POST /orders')
        expect(md).to include('OrdersController')
      end

      it 'produces valid XML context' do
        doc = assembler.assemble('sess1', depth: 1)
        xml = doc.to_context

        expect(xml).to include('<session_context')
        expect(xml).to include('<session_timeline>')
        expect(xml).to include('<unit identifier="OrdersController"')
        expect(xml).to include('</session_context>')
      end

      it 'round-trips through JSON serialization' do
        doc = assembler.assemble('sess1', depth: 1)
        json = JSON.generate(doc.to_h)
        restored = CodebaseIndex::SessionTracer::SessionFlowDocument.from_h(JSON.parse(json))

        expect(restored.session_id).to eq('sess1')
        expect(restored.steps.size).to eq(1)
      end
    end
  end
end
