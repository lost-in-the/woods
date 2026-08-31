# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'

require 'woods'
require 'woods/embedding/fake'
require 'woods/resolved_config'
require 'woods/index_artifact'
require 'woods/storage/snapshotter'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/bootstrap_state'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'
require 'woods/mcp/errors'

# M7 / PR-6b: the MCP +reload+ tool used to +clear!+ then +bulk_load+ the live
# retriever stores, so a concurrent reader could observe an empty or half-loaded
# store window. The lifecycle contract is build-then-swap: candidate stores are
# built off-side against ONE captured generation, any candidate failure leaves
# the previous aligned generation served (with a DISTINCT reload-phase degraded
# condition), and success performs one atomic store-bundle swap under the
# exclusive generation lock after rechecking the generation.
RSpec.describe 'Index MCP transactional store reload' do
  let(:index_dir) { Dir.mktmpdir('woods-mcp-reload-swap') }
  let(:generation) { Woods::Generation.new(output_dir: index_dir) }
  let(:state) { Woods::MCP::BootstrapState.new }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }
  let(:retriever) { Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir).first }
  let(:reloader) do
    ->(rdr) { Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir, reader: rdr, state: state) }
  end
  let(:server) do
    allow(Woods::MCP::IndexReader).to receive(:new).with(index_dir).and_return(reader)
    Woods::MCP::Server.build(
      index_dir: index_dir, retriever: retriever, bootstrap_state: state,
      retriever_reloader: reloader, response_format: :json, warmup: false
    )
  end

  before do
    Woods.configuration.vector_store = :in_memory
    Woods.configuration.metadata_store = :in_memory
    Woods.configuration.graph_store = :in_memory
    Woods.configuration.embedding_provider = :fake
    Woods.configuration.embedding_options = { dims: 4 }

    write_artifact(vector_entries: [['AlphaUnit', [1.0, 0.0, 0.0, 0.0], {}]],
                   metadata_entries: [
                     ['AlphaUnit', { 'type' => 'model', 'identifier' => 'AlphaUnit',
                                     'file_path' => 'app/models/alpha_unit.rb' }]
                   ])
    write_manifest
    generation.bump!(reason: 'initial')
  end

  after { FileUtils.rm_rf(index_dir) }

  describe 'failed reload preservation' do
    it 'keeps the old stores and reader and records a reload-phase degraded condition' do
      server
      old_vector_store = retriever.vector_store
      old_identifier_map = reader.send(:identifier_map)

      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty)
        .and_raise(RuntimeError, 'vectors.bin truncated')

      response = call_tool('reload')

      expect(response.error?).to be(true)
      expect(response.meta[:error_code]).to eq(:degraded_index)
      expect(response.meta[:degraded]).to be(true)
      expect(response.meta[:phase]).to eq('reload')
      expect(response.meta[:generation]).to eq(1)
      expect(response.meta[:stores]).to eq(%w[vector])
      expect(response.meta[:reason]).to include('vectors.bin truncated')

      # Stores and reader untouched: the previous aligned generation is served.
      expect(retriever.vector_store).to be(old_vector_store)
      expect(reader.send(:identifier_map)).to be(old_identifier_map)

      # The DISTINCT reload-phase condition — not the boot degraded machinery.
      expect(state.reload_failed?).to be(true)
      expect(state.status).not_to eq(:degraded)
      expect(state.hydration_failures).to be_empty

      # The old retriever still answers queries.
      retrieval = call_tool('codebase_retrieve', query: 'AlphaUnit model')
      expect(retrieval.error?).to be(false)
      expect(response_text(retrieval)).to include('AlphaUnit')
    end

    it 'exposes the reload condition additively through woods_status' do
      server
      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty)
        .and_raise(RuntimeError, 'vectors.bin unreadable')
      call_tool('reload')

      status = parse_response(call_tool('woods_status'))
      failure = status.dig('bootstrap', 'reload_failure')
      expect(failure).to include(
        'phase' => 'reload',
        'generation' => 1,
        'stores' => %w[vector]
      )
      expect(failure['reason']).to include('vectors.bin unreadable')
      expect(status.dig('bootstrap', 'status')).not_to eq('degraded')
    end
  end

  describe 'successful recovery' do
    it 'swaps atomically and clears the reload-failure condition' do
      server
      old_vector_store = retriever.vector_store
      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty)
        .and_raise(RuntimeError, 'vectors.bin truncated')
      call_tool('reload')
      expect(state.reload_failed?).to be(true)

      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_or_empty).and_call_original
      write_artifact(vector_entries: [['BetaUnit', [0.0, 1.0, 0.0, 0.0], {}]],
                     metadata_entries: [
                       ['BetaUnit', { 'type' => 'service', 'identifier' => 'BetaUnit',
                                      'file_path' => 'app/services/beta_unit.rb' }]
                     ])

      response = call_tool('reload')

      data = parse_response(response)
      expect(data['reloaded']).to be(true)
      expect(data['retriever']).to include('vectors' => 1, 'metadata' => 1, 'graph' => 0)

      # The bundle moved: a NEW store serves the new dump; the old object is retired.
      expect(retriever.vector_store).not_to be(old_vector_store)
      expect(retriever.vector_store.search([0.0, 1.0, 0.0, 0.0], limit: 5).map(&:id)).to eq(%w[BetaUnit])

      expect(state.reload_failed?).to be(false)
      expect(state.reload_failure).to be_nil
    end
  end

  describe 'old-or-new, never empty' do
    it 'lets an in-flight reader finish against the old bundle while the swap lands' do
      server
      old_vector_store = retriever.vector_store
      query_vector = [1.0, 0.0, 0.0, 0.0]

      write_artifact(vector_entries: [['BetaUnit', [0.9, 0.1, 0.0, 0.0], {}]],
                     metadata_entries: [
                       ['BetaUnit', { 'type' => 'model', 'identifier' => 'BetaUnit',
                                      'file_path' => 'app/models/beta_unit.rb' }]
                     ])

      swap_entered = Queue.new
      reader_resolved = Queue.new
      release_reader = Queue.new
      allow(old_vector_store).to receive(:search).and_wrap_original do |original, *args, **kwargs|
        reader_resolved << true
        release_reader.pop
        original.call(*args, **kwargs)
      end
      allow_any_instance_of(Woods::Retriever).to receive(:swap_stores!).and_wrap_original do |original, **kwargs|
        swap_entered << true
        reader_resolved.pop
        result = original.call(**kwargs)
        release_reader << true
        result
      end

      reload_thread = Thread.new { call_tool('reload') }
      Timeout.timeout(5) { swap_entered.pop }

      reader_thread = Thread.new { old_vector_store.search(query_vector, limit: 5) }

      reload_response = reload_thread.value
      results = reader_thread.value

      # The reader entered mid-swap and completed on its resolved snapshot:
      # complete old state — never empty, never mixed with the new bundle.
      expect(results.map(&:id)).to eq(%w[AlphaUnit])
      expect(reload_response.error?).to be(false)

      # New readers see the complete new bundle.
      expect(retriever.vector_store).not_to be(old_vector_store)
      expect(retriever.vector_store.search(query_vector, limit: 5).map(&:id)).to eq(%w[BetaUnit])
    end
  end

  describe 'generation movement during candidate construction' do
    it 'refuses to swap the stale bundle and reports the served generation' do
      server
      old_vector_store = retriever.vector_store
      old_identifier_map = reader.send(:identifier_map)

      allow(Woods::Storage::Snapshotter::Metadata).to receive(:load_or_empty)
        .and_wrap_original do |original, *args, **kwargs|
        generation.bump!(reason: 'concurrent publish')
        original.call(*args, **kwargs)
      end

      response = call_tool('reload')

      expect(response.error?).to be(true)
      expect(response.meta[:error_code]).to eq(:degraded_index)
      expect(response.meta[:phase]).to eq('reload')
      expect(response.meta[:generation]).to eq(1)
      expect(response.meta[:stores]).to eq(%w[vector metadata graph])
      expect(response.meta[:reason]).to include('generation')

      # The stale bundle was NOT swapped; the served generation is retained.
      expect(retriever.vector_store).to be(old_vector_store)
      expect(reader.send(:identifier_map)).to be(old_identifier_map)
      expect(state.reload_failure[:generation]).to eq(1)

      # The old retriever still answers.
      retrieval = call_tool('codebase_retrieve', query: 'AlphaUnit model')
      expect(retrieval.error?).to be(false)
      expect(response_text(retrieval)).to include('AlphaUnit')
    end
  end

  def write_artifact(vector_entries:, metadata_entries:)
    source_vs = Woods::Storage::VectorStore::InMemory.new
    vector_entries.each { |id, vec, meta| source_vs.store(id, vec, meta || {}) }

    source_ms = Woods::Storage::MetadataStore::InMemory.new
    metadata_entries.each { |id, meta| source_ms.store(id, meta) }

    artifact = Woods::IndexArtifact.new(index_dir)
    provider = Woods::Builder.new(Woods.configuration).build_embedding_provider
    resolved = Woods::ResolvedConfig.from_configuration(Woods.configuration, provider: provider)
    dump_dir = artifact.dumps_root.join("dump-#{Process.pid}-#{rand(1_000_000)}")

    Woods::Storage::Snapshotter::Vector.dump(source_vs, artifact, dump_dir, resolved_config: resolved)
    Woods::Storage::Snapshotter::Metadata.dump(source_ms, artifact, dump_dir, resolved_config: resolved)
    artifact.write_config(resolved.to_snapshot_json)
    artifact.promote(dump_dir)
  end

  def write_manifest
    File.write(File.join(index_dir, 'manifest.json'), JSON.generate(
                                                        'extracted_at' => '2026-08-31T00:00:00Z',
                                                        'total_units' => 1,
                                                        'counts' => { 'models' => 1 }
                                                      ))
  end

  def call_tool(tool_name, **args)
    tools = server.instance_variable_get(:@tools)
    tool_class = tools[tool_name]
    raise "Tool not found: #{tool_name}" unless tool_class

    tool_class.call(**args, server_context: {})
  end

  def response_text(response)
    response.content.first[:text]
  end

  def parse_response(response)
    JSON.parse(response_text(response))
  end
end
