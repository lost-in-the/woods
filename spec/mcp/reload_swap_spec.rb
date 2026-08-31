# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'timeout'

require 'woods'
require 'woods/embedding/fake'
require 'woods/resolved_config'
require 'woods/index_artifact'
require 'woods/storage/snapshotter'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/coordination/pipeline_lock'
require 'woods/watch/daemon'
require 'woods/mcp/bootstrapper'
require 'woods/mcp/bootstrap_state'
require 'woods/mcp/index_reader'
require 'woods/mcp/server'
require 'woods/mcp/errors'

# M7 / PR-6b: the MCP +reload+ tool used to +clear!+ then +bulk_load+ the live
# retriever stores, so a concurrent reader could observe an empty or half-loaded
# store window. The lifecycle contract is build-then-swap: candidate stores are
# built off-side against ONE captured (generation marker, promoted dump
# identity) pair, read exclusively from those captured locations; any candidate
# failure or identity movement leaves the previous aligned generation served
# (with a DISTINCT reload-phase degraded condition); and the commit holds the
# extraction PipelineLock across the recheck and the one-assignment store
# bundle swap, so no writer publication can interleave between recheck and
# swap.
RSpec.describe 'Index MCP transactional store reload' do
  let(:index_dir) { Dir.mktmpdir('woods-mcp-reload-swap') }
  let(:generation) { Woods::Generation.new(output_dir: index_dir) }
  let(:state) { Woods::MCP::BootstrapState.new }
  let(:reader) { Woods::MCP::IndexReader.new(index_dir) }
  let(:retriever) { Woods::MCP::Bootstrapper.build_retriever(index_dir: index_dir).first }
  # Deterministic-interleaving hooks reach the transaction through this slot:
  # the reload tool's reloader callable is the production path, and the tool
  # passes no hooks itself, so the spec swaps them in via the closure.
  let(:reload_hooks) { {} }
  let(:reloader) do
    lambda do |rdr|
      Woods::MCP::Bootstrapper.reload_stores!(retriever, index_dir: index_dir, reader: rdr,
                                                         state: state, hooks: reload_hooks[:current])
    end
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

    write_artifact(identifier: 'AlphaUnit', type: 'model', vector: [1.0, 0.0, 0.0, 0.0],
                   file_path: 'app/models/alpha_unit.rb')
    write_manifest
    generation.bump!(reason: 'initial')
  end

  after { FileUtils.rm_rf(index_dir) }

  describe 'failed reload preservation' do
    it 'keeps the old stores and reader and records a reload-phase degraded condition' do
      server
      old_vector_store = retriever.vector_store
      old_identifier_map = reader.send(:identifier_map)

      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_dump_dir)
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
      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_dump_dir)
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
      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_dump_dir)
        .and_raise(RuntimeError, 'vectors.bin truncated')
      call_tool('reload')
      expect(state.reload_failed?).to be(true)

      allow(Woods::Storage::Snapshotter::Vector).to receive(:load_dump_dir).and_call_original
      write_artifact(identifier: 'BetaUnit', type: 'service', vector: [0.0, 1.0, 0.0, 0.0],
                     file_path: 'app/services/beta_unit.rb')

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
    it 'lets an in-flight retrieve finish entirely on the old bundle while the swap lands' do
      server
      old_vector_store = retriever.vector_store
      # Dump-only publication (embed promotes without touching the JSON payload
      # generation): the new dump is what a reload should pick up.
      write_artifact(identifier: 'BetaUnit', type: 'service', vector: [0.9, 0.1, 0.0, 0.0],
                     file_path: 'app/services/beta_unit.rb')

      resolved_old = Queue.new
      release_reader = Queue.new
      retriever.pipeline_observer = lambda do |_pipeline|
        resolved_old << true
        release_reader.pop
      end

      reload_thread = Thread.new do
        reload_hooks[:current] = {
          before_swap: -> { resolved_old.pop },
          after_swap: -> { release_reader << true }
        }
        reloader.call(reader)
      end

      # The ACTUAL production retrieval path: retrieve resolves the old bundle,
      # signals through the observer, and blocks until the swap has landed.
      result = retriever.retrieve('AlphaUnit model')
      reload_result = reload_thread.value

      # The in-flight response is ENTIRELY old: every unit from the old dump,
      # nothing from the new one.
      expect(result.context).to include('AlphaUnit')
      expect(result.context).not_to include('BetaUnit')
      expect(result.sources.map { |s| s[:identifier] }).to all(eq('AlphaUnit'))

      expect(reload_result).to include(vectors: 1, metadata: 1)

      # The retired bundle is untouched (in-flight readers finish against it).
      expect(old_vector_store.search([1.0, 0.0, 0.0, 0.0], limit: 5).map(&:id)).to eq(%w[AlphaUnit])

      # A subsequent response is ENTIRELY new.
      retriever.pipeline_observer = nil
      second = retriever.retrieve('BetaUnit service')
      expect(second.context).to include('BetaUnit')
      expect(second.context).not_to include('AlphaUnit')
    end
  end

  describe 'generation movement during candidate construction' do
    it 'refuses to swap the stale bundle and reports the served generation' do
      server
      old_pipeline = retriever.pipeline
      old_vector_store = retriever.vector_store
      old_identifier_map = reader.send(:identifier_map)
      reload_hooks[:current] = { after_vector_candidate: -> { generation.bump!(reason: 'concurrent publish') } }

      response = call_tool('reload')

      expect(response.error?).to be(true)
      expect(response.meta[:error_code]).to eq(:degraded_index)
      expect(response.meta[:phase]).to eq('reload')
      expect(response.meta[:generation]).to eq(1)
      expect(response.meta[:stores]).to eq(%w[vector metadata graph])
      expect(response.meta[:reason]).to include('generation')

      # The stale bundle was NOT swapped; the served generation is retained.
      expect(retriever.pipeline).to be(old_pipeline)
      expect(retriever.vector_store).to be(old_vector_store)
      expect(reader.send(:identifier_map)).to be(old_identifier_map)
      expect(state.reload_failure[:generation]).to eq(1)

      # The old retriever still answers.
      retrieval = call_tool('codebase_retrieve', query: 'AlphaUnit model')
      expect(retrieval.error?).to be(false)
      expect(response_text(retrieval)).to include('AlphaUnit')
    end
  end

  describe 'promoted dump identity' do
    it 'refuses to mix halves from two dumps when dumps/latest moves between hydrations' do
      server
      old_pipeline = retriever.pipeline
      old_vector_store = retriever.vector_store
      captured_dump = Woods::IndexArtifact.new(index_dir).latest_dump_path
      reload_hooks[:current] = {
        # The writer promotes a second dump AFTER the vector candidate
        # hydrated but BEFORE the metadata candidate. Compatible dimensions:
        # only the identity recheck can tell the halves apart.
        after_vector_candidate: lambda do
          write_artifact(identifier: 'BetaUnit', type: 'service', vector: [0.0, 1.0, 0.0, 0.0],
                         file_path: 'app/services/beta_unit.rb')
        end
      }

      reload_error = nil
      Thread.new do
        reloader.call(reader)
      rescue StandardError => e
        reload_error = e
      end.join(10)

      expect(reload_error).to be_a(Woods::MCP::ReloadDumpMoved)
      expect(reload_error.generation).to eq(1)
      expect(reload_error.stores).to eq(%w[vector metadata graph])

      # Nothing swapped, nothing mixed: the old pipeline and stores are exactly
      # the objects that were serving before the attempt.
      expect(retriever.pipeline).to be(old_pipeline)
      expect(retriever.vector_store).to be(old_vector_store)
      expect(retriever.vector_store.search([1.0, 0.0, 0.0, 0.0], limit: 5).map(&:id)).to eq(%w[AlphaUnit])
      expect(state.reload_failure[:reason]).to include('dump')
      expect(Woods::IndexArtifact.new(index_dir).latest_dump_path.to_s).not_to eq(captured_dump.to_s)
    end
  end

  describe 'writer publication against the commit window' do
    it 'blocks a writer until the commit finishes, then serves the new generation on the next reload' do
      server
      old_pipeline = retriever.pipeline
      captured_dump = Woods::IndexArtifact.new(index_dir).latest_dump_path

      lock_held = Queue.new
      release_reload = Queue.new
      reload_hooks[:current] = {
        after_pipeline_lock: lambda {
          lock_held << true
          release_reload.pop
        }
      }
      reload_thread = Thread.new { reloader.call(reader) }
      Timeout.timeout(5) { lock_held.pop }

      writer_attempting = Queue.new
      writer_published = Queue.new
      writer = Thread.new do
        Woods::IndexArtifact.new(index_dir)
        lock = Woods::Coordination::PipelineLock.new(
          lock_dir: index_dir, name: Woods::Watch::Daemon::LOCK_NAME,
          stale_timeout: Woods::Watch::Daemon::LOCK_STALE_TIMEOUT
        )
        writer_attempting << true
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        acquired = lock.acquire
        until acquired || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.05
          acquired = lock.acquire
        end
        next unless acquired

        begin
          write_artifact(identifier: 'BetaUnit', type: 'service', vector: [0.0, 1.0, 0.0, 0.0],
                         file_path: 'app/services/beta_unit.rb')
          Woods::Generation.new(output_dir: index_dir).bump!(reason: 'writer publish')
        ensure
          lock.release
        end
        writer_published << true
      end
      Timeout.timeout(5) { writer_attempting.pop }

      # The reload holds the extraction PipelineLock across the recheck and the
      # swap, so the writer's publication CANNOT interleave into that window.
      writer_blocked = !writer.join(0.3)
      expect(writer_blocked).to be(true)
      expect(Woods::IndexArtifact.new(index_dir).latest_dump_path.to_s).to eq(captured_dump.to_s)

      # Commit lands on the captured identity, then the lock releases and the
      # blocked writer publishes.
      release_reload << true
      reload_result = reload_thread.value
      expect(reload_result).to include(vectors: 1, metadata: 1)
      expect(retriever.pipeline).not_to be(old_pipeline)
      expect(retriever.vector_store.search([1.0, 0.0, 0.0, 0.0], limit: 5).map(&:id)).to eq(%w[AlphaUnit])
      Timeout.timeout(5) { writer_published.pop }

      # A LATER reload sees the moved identity: it re-captures, rebuilds
      # candidates from the new dump, and swaps to it.
      reload_hooks[:current] = nil
      reloader.call(reader)
      expect(retriever.vector_store.search([0.0, 1.0, 0.0, 0.0], limit: 5).map(&:id)).to eq(%w[BetaUnit])
    ensure
      release_reload << true
      reload_thread&.join(5)
      writer&.join(5)
    end
  end

  def write_artifact(identifier:, type:, vector:, file_path:)
    source_vs = Woods::Storage::VectorStore::InMemory.new
    source_vs.store(identifier, vector, {})

    source_ms = Woods::Storage::MetadataStore::InMemory.new
    source_ms.store(identifier, { 'type' => type, 'identifier' => identifier, 'file_path' => file_path })

    artifact = Woods::IndexArtifact.new(index_dir)
    provider = Woods::Builder.new(Woods.configuration).build_embedding_provider
    resolved = Woods::ResolvedConfig.from_configuration(Woods.configuration, provider: provider)
    dump_dir = artifact.dumps_root.join("dump-#{Process.pid}-#{rand(1_000_000)}")
    FileUtils.mkdir_p(dump_dir)

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
