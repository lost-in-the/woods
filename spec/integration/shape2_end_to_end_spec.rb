# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'json'
require 'woods'
require 'woods/mcp/bootstrapper'
require 'woods/index_artifact'
require 'woods/resolved_config'
require 'woods/storage/snapshotter'
require 'woods/storage/vector_store'
require 'woods/storage/metadata_store'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/tasks'

# End-to-end integration specs for the Shape-2 (shared-filesystem) deployment
# path. Three critical bugs survived PR #73–#78 because no spec exercised the
# full dump → boot → search cycle together:
#
#   Bug 1 — Bootstrapper stub (PR #75): build_retriever_from_config called
#     Builder.new(config).build_retriever without threading the hydrated
#     stores through — every MCP boot started with empty stores regardless of
#     what the Indexer had written to disk.
#
#   Bug 2 — :dimension leaking into provider kwargs (PR #78 / #79): woods.json
#     stores :dimension in embedding_provider for ResolvedConfig, and
#     populate_from_stored put it in embedding_options. Ollama.new / OpenAI.new
#     do not accept :dimension — the provider constructor raised ArgumentError
#     silently swallowed by the outer rescue, producing a nil retriever.
#
#   Bug 3 — Metadata not back-filled into vector store (PR #79): after
#     Snapshotter::Vector loads a dump, the per-entry metadata hashes are
#     empty {} (vectors.bin is numeric only). Bootstrapper.populate_vector_metadata
#     was the fix; without it type-filtered searches return zero results even
#     though the correct vectors are present.
#
# Each spec is written to fail on the pre-fix codebase and pass on the post-fix
# one. All embedding calls are stubbed — no network access.
#
# Defined outside the describe block to satisfy Lint/ConstantDefinitionInBlock.
Shape2StubConfig = Struct.new(
  :embedding_provider, :embedding_model, :embedding_options,
  :vector_store, :vector_store_options, :metadata_store, :graph_store,
  keyword_init: true
)

RSpec.describe 'Shape-2 end-to-end: dump → boot → search' do
  # ── Shared helpers ──────────────────────────────────────────────────────────

  let(:dim) { 4 }

  # Unit vectors so cosine scores are exact (dot product == cosine similarity).
  let(:vec_foo) { [1.0, 0.0, 0.0, 0.0] }
  let(:vec_bar) { [0.0, 1.0, 0.0, 0.0] }
  let(:vec_baz) { [0.0, 0.0, 1.0, 0.0] }

  let(:meta_foo) { { 'type' => 'model',   'namespace' => 'Admin' } }
  let(:meta_bar) { { 'type' => 'service', 'namespace' => 'Admin' } }
  let(:meta_baz) { { 'type' => 'model',   'namespace' => 'Public' } }

  def stub_resolved_config
    Woods::ResolvedConfig.from_configuration(
      Shape2StubConfig.new(
        embedding_provider: :ollama,
        embedding_model: 'nomic-embed-text',
        embedding_options: {
          model: 'nomic-embed-text',
          host: 'http://localhost:11434',
          dimension: dim
        },
        vector_store: :in_memory,
        metadata_store: :in_memory,
        graph_store: :in_memory
      )
    )
  end

  def build_populated_stores
    vs = Woods::Storage::VectorStore::InMemory.new
    vs.store('Foo', vec_foo, meta_foo)
    vs.store('Bar', vec_bar, meta_bar)
    vs.store('Baz', vec_baz, meta_baz)

    ms = Woods::Storage::MetadataStore::InMemory.new
    ms.store('Foo', meta_foo)
    ms.store('Bar', meta_bar)
    ms.store('Baz', meta_baz)

    [vs, ms]
  end

  # Write a fully-formed dump into output_dir and return [artifact, resolved].
  def write_dump(output_dir)
    vs, ms = build_populated_stores
    artifact = Woods::IndexArtifact.new(output_dir)
    resolved = stub_resolved_config
    dump_dir = artifact.new_dump_dir
    Woods::Storage::Snapshotter::Vector.dump(vs, artifact, dump_dir, resolved_config: resolved)
    Woods::Storage::Snapshotter::Metadata.dump(ms, artifact, dump_dir, resolved_config: resolved)
    artifact.write_config(resolved.to_snapshot_json)
    artifact.promote(dump_dir)
    [artifact, resolved]
  end

  # Configure Woods.configuration to match the dump and stub the provider so
  # ProviderProbe does not make real network calls.
  def configure_woods_for_shape2(output_dir)
    Woods.configuration.vector_store       = :in_memory
    Woods.configuration.metadata_store     = :in_memory
    Woods.configuration.graph_store        = :in_memory
    Woods.configuration.embedding_provider = :ollama
    Woods.configuration.embedding_options  = {
      host: 'http://127.0.0.1:19999', # unreachable — probe will degrade, not raise
      model: 'nomic-embed-text',
      dimension: dim # Bug 2: must not reach Ollama.new
    }
    Woods.configuration.output_dir = output_dir
  end

  around do |example|
    original = Woods.configuration
    Woods.configuration = Woods::Configuration.new
    ENV.delete('WOODS_ALLOW_AUTODETECT')
    example.run
  ensure
    Woods.configuration = original
  end

  # ── Bug 1: Bootstrapper hydrates from Snapshotter dumps ────────────────────
  describe 'Bug 1 — Bootstrapper must hydrate stores from the latest dump' do
    # Before the fix, build_retriever_from_config called
    #   Woods::Builder.new(config).build_retriever
    # without threading vector_store: / metadata_store: through, so the
    # retriever always started with empty stores even when dumps existed.
    it 'returns a retriever whose vector store contains every dumped vector' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        expect(retriever).not_to be_nil
        vs = retriever.vector_store
        expect(vs.count).to eq(3),
                            'vector store should have 3 entries after boot; ' \
                            'got 0 — Bootstrapper did not hydrate from the dump (Bug 1)'
        expect(vs.each_entry.map { |id, _vec, _meta| id }).to contain_exactly('Foo', 'Bar', 'Baz')
      end
    end

    it 'returns a retriever whose metadata store contains every dumped record' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        ms = retriever.metadata_store
        expect(ms.count).to eq(3),
                            'metadata store should have 3 entries after boot; ' \
                            'got 0 — Bootstrapper did not hydrate from the dump (Bug 1)'
        expect(ms.find('Foo')).to include('type' => 'model')
        expect(ms.find('Bar')).to include('type' => 'service')
      end
    end

    it 'marks BootstrapState as :degraded (not :failed) when provider is unreachable' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        _retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        # Provider unreachable → degraded, not failed. The retriever still
        # comes back non-nil and the stores are hydrated.
        expect(state.status).to eq(:degraded)
        expect(state.reason).to be_a(Woods::MCP::ProviderUnreachable)
      end
    end
  end

  # ── Bug 2: :dimension must not reach the provider constructor ───────────────
  describe 'Bug 2 — :dimension in embedding_options must not reach Ollama.new' do
    # Before the fix, populate_from_stored put :dimension (stored by
    # ResolvedConfig for schema bookkeeping) into config.embedding_options and
    # Builder passed it to Ollama.new, which raised ArgumentError because
    # Ollama does not accept a :dimension kwarg.
    #
    # The failure was swallowed by a rescue StandardError in the old
    # hydration path, returning nil + a warning — operators saw no retriever
    # and no actionable error.
    it 'boots without raising ArgumentError when :dimension is in embedding_options' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        # The key assertion: no exception escapes. Before the fix this raised
        # ArgumentError (unknown keyword: dimension) inside Ollama.new.
        expect do
          Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        end.not_to raise_error
      end
    end

    it 'constructs a live Ollama provider even when :dimension is present in options' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        # If Ollama.new succeeded, the retriever exposes a provider that is
        # an Ollama instance (not a nil or a stub).
        expect(retriever).not_to be_nil
        provider = retriever.pipeline.executor.instance_variable_get(:@embedding_provider)
        # Unwrap CachedEmbeddingProvider if present.
        provider = provider.instance_variable_get(:@provider) if provider.respond_to?(:instance_variable_get) &&
                                                                 provider.instance_variable_get(:@provider)
        expect(provider).to be_a(Woods::Embedding::Provider::Ollama)
      end
    end
  end

  # ── Bug 3: Vector store metadata must be back-filled after hydration ─────────
  describe 'Bug 3 — per-entry metadata must be back-filled from the metadata store' do
    # vectors.bin stores only id + float32 data — no per-vector metadata hash.
    # Snapshotter::Vector.load_or_empty therefore populates @metadata with
    # empty {} hashes. InMemory::VectorStore#search filters candidates by
    # comparing @metadata entries against the caller's filter hash. Without the
    # back-fill step, type-filtered searches always return zero results even
    # though the correct vectors are present.
    it 'returns results for an unfiltered search after dump/reload' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        vs = retriever.vector_store

        results = vs.search(vec_foo, limit: 3, filters: {})
        expect(results).not_to be_empty,
                               'unfiltered search returned nothing — ' \
                               'vector store may not have been hydrated (Bug 1/3)'
        expect(results.first.id).to eq('Foo')
      end
    end

    it 'returns the correct entries when filtered by type after dump/reload' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        vs = retriever.vector_store

        model_results = vs.search(vec_foo, limit: 10, filters: { 'type' => 'model' })
        expect(model_results.map(&:id)).to contain_exactly('Foo', 'Baz'),
                                           'type=model filter should return Foo and Baz; ' \
                                           "got #{model_results.map(&:id).inspect} — " \
                                           'metadata was not back-filled into vector store (Bug 3)'
      end
    end

    it 'type-filtered search excludes entries that do not match the filter' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        vs = retriever.vector_store

        service_results = vs.search(vec_bar, limit: 10, filters: { 'type' => 'service' })
        expect(service_results.map(&:id)).to eq(['Bar']),
                                             'type=service filter should return only Bar; ' \
                                             "got #{service_results.map(&:id).inspect} — " \
                                             'metadata back-fill or filter logic is broken (Bug 3)'
      end
    end

    it 'namespace filter works correctly after dump/reload' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
        vs = retriever.vector_store

        admin_results = vs.search(vec_foo, limit: 10, filters: { 'namespace' => 'Admin' })
        expect(admin_results.map(&:id)).to contain_exactly('Foo', 'Bar'),
                                           'namespace=Admin filter should return Foo and Bar; ' \
                                           "got #{admin_results.map(&:id).inspect} — " \
                                           'metadata back-fill produced wrong or missing hashes (Bug 3)'
      end
    end
  end

  # ── Full cycle: dump, fresh boot, search returns ranked results ─────────────
  describe 'Full Shape-2 cycle — dump in one context, search after re-boot' do
    # This is the narrative test: what an operator would see if they ran
    # `rake woods:embed` and then started `woods-mcp`. The combination of
    # all three bug fixes must hold simultaneously.
    it 'returns semantically ranked results for a query vector after dump/reload' do
      Dir.mktmpdir do |dir|
        write_dump(dir)
        configure_woods_for_shape2(dir)

        retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        expect(retriever).not_to be_nil
        # Degraded is expected since the Ollama URL is unreachable.
        expect(%i[hydrated degraded]).to include(state.status)

        vs = retriever.vector_store

        # Query with vec_bar — Bar should be closest (dot product 1.0).
        results = vs.search(vec_bar, limit: 2, filters: {})
        expect(results).not_to be_empty
        expect(results.first.id).to eq('Bar')
        expect(results.first.score).to be_within(1e-5).of(1.0)
      end
    end

    it 'preserves vector precision (float32 round-trip) within 1e-5 tolerance' do
      # Pack/unpack through vectors.bin uses float32 — we accept a small
      # precision loss from the Float64 originals.
      Dir.mktmpdir do |dir|
        # Build a non-trivial vector that will lose some float32 precision.
        rng = Random.new(42)
        raw_vec = Array.new(dim) { rng.rand(-1.0..1.0) }
        mag = Math.sqrt(raw_vec.sum { |x| x * x })
        precise_vec = raw_vec.map { |x| x / mag }

        vs = Woods::Storage::VectorStore::InMemory.new
        vs.store('Precise', precise_vec, { 'type' => 'model' })
        ms = Woods::Storage::MetadataStore::InMemory.new
        ms.store('Precise', { 'type' => 'model' })

        artifact = Woods::IndexArtifact.new(dir)
        resolved = Woods::ResolvedConfig.from_configuration(
          Shape2StubConfig.new(
            embedding_provider: :ollama,
            embedding_model: 'nomic-embed-text',
            embedding_options: { model: 'nomic-embed-text', host: 'http://localhost:11434', dimension: dim },
            vector_store: :in_memory, metadata_store: :in_memory, graph_store: :in_memory
          )
        )

        dump_dir = artifact.new_dump_dir
        Woods::Storage::Snapshotter::Vector.dump(vs, artifact, dump_dir, resolved_config: resolved)
        artifact.promote(dump_dir)

        loaded = Woods::Storage::Snapshotter::Vector.load_or_empty(artifact, resolved_config: resolved)
        loaded_vec = loaded.each_entry.first[1]

        precise_vec.each_with_index do |orig, i|
          expect(loaded_vec[i]).to be_within(1e-5).of(orig),
                                   "float32 round-trip exceeded 1e-5 tolerance at index #{i}"
        end
      end
    end

    it 'woods.json is readable and round-trips through ResolvedConfig' do
      Dir.mktmpdir do |dir|
        _artifact, resolved = write_dump(dir)
        artifact2 = Woods::IndexArtifact.new(dir)

        raw = artifact2.read_config
        expect(raw).not_to be_nil

        reloaded = Woods::ResolvedConfig.from_hash(raw)
        expect(reloaded.dimension).to eq(dim)
        expect(reloaded.stores[:vector_store]).to eq(:in_memory)
        expect(reloaded.provider_signature).to include('nomic-embed-text')
        expect(reloaded.matches?(resolved)).to be true
      end
    end
  end

  # ── Scenario 2 & 3: Tasks.build_embed_indexer writes artifacts + round-trip ─
  describe 'Tasks.build_embed_indexer writes all Shape-2 artifacts' do
    # The critical bug this covers: Tasks.build_embed_indexer never passed
    # resolved_config to the Indexer, so woods.json was never written and the
    # standalone woods-mcp server could never boot in Shape-2 mode.

    let(:stub_dim) { 4 }

    # Fake unit JSON — the Indexer's load_units reads *.json from output_dir.
    def write_unit_json(dir, id:, type:)
      data = {
        'type' => type, 'identifier' => id,
        'file_path' => "app/#{type}s/#{id.downcase}.rb",
        'source_code' => "class #{id}; end",
        'source_hash' => Digest::MD5.hexdigest(id),
        'namespace' => nil, 'dependencies' => [], 'chunks' => []
      }
      File.write(File.join(dir, "#{id}.json"), JSON.generate(data))
    end

    # Build a provider double that returns deterministic unit vectors per call.
    def stub_provider(dim)
      rng = Random.new(99)
      provider = instance_double(
        Woods::Embedding::Provider::Ollama,
        model_name: 'nomic-embed-text',
        max_input_tokens: 2048
      )
      allow(provider).to receive(:embed_batch) do |texts|
        texts.map do
          v = Array.new(dim) { rng.rand(-1.0..1.0) }
          mag = Math.sqrt(v.sum { |x| x * x })
          v.map { |x| x / mag }
        end
      end
      provider
    end

    def configure_woods_for_indexer(output_dir, dim:)
      Woods.configuration.vector_store = :in_memory
      Woods.configuration.metadata_store = :in_memory
      Woods.configuration.graph_store = :in_memory
      Woods.configuration.embedding_provider = :ollama
      Woods.configuration.embedding_options = {
        model: 'nomic-embed-text',
        host: 'http://localhost:11434',
        dimension: dim
      }
      Woods.configuration.output_dir = output_dir
    end

    it 'writes woods.json with schema_version=1 after index_all' do
      Dir.mktmpdir do |dir|
        configure_woods_for_indexer(dir, dim: stub_dim)
        write_unit_json(dir, id: 'User', type: 'model')
        write_unit_json(dir, id: 'OrdersController', type: 'controller')

        provider = stub_provider(stub_dim)
        indexer = Woods::Embedding::Indexer.new(
          provider: provider,
          text_preparer: Woods::Embedding::TextPreparer.new,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          resolved_config: Woods::Tasks.build_resolved_config(Woods.configuration),
          chunker: nil,
          output_dir: dir
        )
        indexer.index_all

        woods_json_path = File.join(dir, 'woods.json')
        expect(File.exist?(woods_json_path)).to(
          be(true),
          'woods.json was not written — Tasks.build_embed_indexer must pass resolved_config to Indexer'
        )
        parsed = JSON.parse(File.read(woods_json_path))
        expect(parsed['schema_version']).to eq(1)
        expect(parsed.dig('embedding_provider', 'class')).to include('Ollama')
      end
    end

    it 'writes vectors.bin inside a timestamped dump dir after index_all' do
      Dir.mktmpdir do |dir|
        configure_woods_for_indexer(dir, dim: stub_dim)
        write_unit_json(dir, id: 'Post', type: 'model')

        provider = stub_provider(stub_dim)
        indexer = Woods::Embedding::Indexer.new(
          provider: provider,
          text_preparer: Woods::Embedding::TextPreparer.new,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          resolved_config: Woods::Tasks.build_resolved_config(Woods.configuration),
          chunker: nil,
          output_dir: dir
        )
        indexer.index_all

        latest_pointer = File.join(dir, 'dumps', 'latest')
        expect(File.exist?(latest_pointer)).to(be(true), 'dumps/latest pointer not written')

        dump_name = File.read(latest_pointer).strip
        expect(dump_name).not_to be_empty

        vectors_bin = File.join(dir, 'dumps', dump_name, 'vectors.bin')
        expect(File.exist?(vectors_bin)).to(
          be(true),
          "dumps/#{dump_name}/vectors.bin not found — Indexer did not persist the vector snapshot"
        )
      end
    end

    it 'writes metadata.msgpack alongside vectors.bin' do
      Dir.mktmpdir do |dir|
        configure_woods_for_indexer(dir, dim: stub_dim)
        write_unit_json(dir, id: 'Comment', type: 'model')

        provider = stub_provider(stub_dim)
        indexer = Woods::Embedding::Indexer.new(
          provider: provider,
          text_preparer: Woods::Embedding::TextPreparer.new,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          resolved_config: Woods::Tasks.build_resolved_config(Woods.configuration),
          chunker: nil,
          output_dir: dir
        )
        indexer.index_all

        dump_name = File.read(File.join(dir, 'dumps', 'latest')).strip
        meta_path = File.join(dir, 'dumps', dump_name, 'metadata.msgpack')
        expect(File.exist?(meta_path)).to(be(true), 'metadata.msgpack not written alongside vectors.bin')
      end
    end

    # Scenario 3: full round-trip — indexer writes, Bootstrapper reads back.
    it 'Bootstrapper.build_retriever reads back units written by the Indexer' do
      Dir.mktmpdir do |dir|
        configure_woods_for_indexer(dir, dim: stub_dim)
        write_unit_json(dir, id: 'Tag', type: 'model')
        write_unit_json(dir, id: 'TagService', type: 'service')

        provider = stub_provider(stub_dim)
        indexer = Woods::Embedding::Indexer.new(
          provider: provider,
          text_preparer: Woods::Embedding::TextPreparer.new,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          resolved_config: Woods::Tasks.build_resolved_config(Woods.configuration),
          chunker: nil,
          output_dir: dir
        )
        indexer.index_all

        # Simulate MCP boot in a fresh context — no provider configured.
        Woods.configuration = Woods::Configuration.new
        ENV.delete('WOODS_ALLOW_AUTODETECT')

        # Boot with unreachable provider (unit tests can't reach Ollama).
        retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        expect(retriever).not_to be_nil,
                                 'Bootstrapper returned nil — round-trip from Indexer to Bootstrapper failed'
        expect(%i[hydrated degraded]).to include(state.status)

        vs = retriever.vector_store
        expect(vs.count).to eq(2),
                            "expected 2 vectors from Indexer dump, got #{vs.count}"
      end
    end
  end

  # ── Scenario 4: dump_retention_count is honored ─────────────────────────────
  describe 'Indexer#persist_snapshot respects dump_retention_count' do
    def write_one_unit(dir, id)
      data = {
        'type' => 'model', 'identifier' => id,
        'file_path' => "app/models/#{id.downcase}.rb",
        'source_code' => "class #{id}; end",
        'source_hash' => Digest::MD5.hexdigest(id),
        'namespace' => nil, 'dependencies' => [], 'chunks' => []
      }
      File.write(File.join(dir, "#{id}.json"), JSON.generate(data))
    end

    def stub_simple_provider(dim)
      provider = instance_double(
        Woods::Embedding::Provider::Ollama,
        model_name: 'nomic-embed-text',
        max_input_tokens: 2048
      )
      rng = Random.new(7)
      allow(provider).to receive(:embed_batch) do |texts|
        texts.map do
          v = Array.new(dim) { rng.rand(-1.0..1.0) }
          mag = Math.sqrt(v.sum { |x| x * x })
          v.map { |x| x / mag }
        end
      end
      provider
    end

    # Write a complete dump with a specific timestamp into artifact.
    def write_timed_dump(artifact, now, dim)
      vs = Woods::Storage::VectorStore::InMemory.new
      vs.store('Unit', Array.new(dim) { 0.5 }, {})
      rc = stub_resolved_config
      dump_dir = artifact.new_dump_dir(now: now)
      Woods::Storage::Snapshotter::Vector.dump(vs, artifact, dump_dir, resolved_config: rc)
      artifact.promote(dump_dir)
      dump_dir
    end

    it 'prunes oldest dumps when more than retention_count exist' do
      Dir.mktmpdir do |dir|
        dim = 4
        write_one_unit(dir, 'Alpha')
        artifact = Woods::IndexArtifact.new(dir)

        # Write 3 dumps manually at distinct timestamps so we have a stable
        # baseline before the Indexer adds a fourth.
        times = [
          Time.utc(2026, 4, 23, 10, 0, 0),
          Time.utc(2026, 4, 23, 10, 0, 1),
          Time.utc(2026, 4, 23, 10, 0, 2)
        ]
        times.each { |t| write_timed_dump(artifact, t, dim) }

        # Now run the Indexer with retention=2. It creates a 4th dump, then
        # prune_old_dumps should remove the 2 oldest, leaving 2 total.
        provider = stub_simple_provider(dim)
        rc = stub_resolved_config
        indexer = Woods::Embedding::Indexer.new(
          provider: provider,
          text_preparer: Woods::Embedding::TextPreparer.new,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          resolved_config: rc,
          chunker: nil,
          output_dir: dir,
          dump_retention_count: 2
        )
        indexer.index_all

        dumps_root = File.join(dir, 'dumps')
        dump_dirs = Dir.glob(File.join(dumps_root, '20*')).select { |p| File.directory?(p) }
        expect(dump_dirs.size).to eq(2),
                                  'expected 2 dumps after 4 total runs with retention=2, ' \
                                  "got #{dump_dirs.size}: #{dump_dirs.map { |d| File.basename(d) }}"
      end
    end
  end

  # ── Scenario 5: Standalone Shape-2 — no Rails, woods.json drives config ──────
  describe 'Standalone Shape-2 — woods.json drives config for fresh Configuration' do
    # The Bootstrapper must be able to boot entirely from woods.json when no
    # host Rails initializer ran. This is the "separate MCP server" case.
    it 'populates provider from woods.json when config has no provider' do
      Dir.mktmpdir do |dir|
        # Write dumps as if a prior embed happened.
        write_dump(dir)

        # Fresh Configuration — no provider, no initializer.
        fresh_config = Woods::Configuration.new
        allow(Woods).to receive(:configuration).and_return(fresh_config)
        ENV.delete('WOODS_ALLOW_AUTODETECT')

        retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        expect(retriever).not_to be_nil,
                                 'Bootstrapper returned nil with a fresh config — ' \
                                 'it should have populated provider from woods.json'
        expect(%i[hydrated degraded]).to include(state.status)
      end
    end

    it 'hydrates vector store entries after loading config from woods.json' do
      Dir.mktmpdir do |dir|
        write_dump(dir)

        fresh_config = Woods::Configuration.new
        allow(Woods).to receive(:configuration).and_return(fresh_config)
        ENV.delete('WOODS_ALLOW_AUTODETECT')

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        vs = retriever.vector_store
        expect(vs.count).to eq(3),
                            'vector store should have 3 entries loaded from dump via standalone boot; ' \
                            "got #{vs.count}"
      end
    end

    it 'type-filtered search works after standalone boot from woods.json' do
      Dir.mktmpdir do |dir|
        write_dump(dir)

        fresh_config = Woods::Configuration.new
        allow(Woods).to receive(:configuration).and_return(fresh_config)
        ENV.delete('WOODS_ALLOW_AUTODETECT')

        retriever, _state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)

        vs = retriever.vector_store

        model_results = vs.search(vec_foo, limit: 10, filters: { 'type' => 'model' })
        expect(model_results.map(&:id)).to contain_exactly('Foo', 'Baz'),
                                           'type=model filter failed after standalone boot — ' \
                                           "got #{model_results.map(&:id).inspect}"
      end
    end
  end

  # ── Scenario 6: OpenAI woods.json requires OPENAI_API_KEY ────────────────────
  describe 'OpenAI snapshot raises MissingCredential when OPENAI_API_KEY is absent' do
    # Write a woods.json that records an OpenAI-embedded index.
    def write_openai_dump(output_dir) # rubocop:disable Metrics/MethodLength
      vs = Woods::Storage::VectorStore::InMemory.new
      vs.store('Foo', [1.0, 0.0, 0.0, 0.0], { 'type' => 'model' })

      ms = Woods::Storage::MetadataStore::InMemory.new
      ms.store('Foo', { 'type' => 'model' })

      resolved = Woods::ResolvedConfig.from_configuration(
        Shape2StubConfig.new(
          embedding_provider: :openai,
          embedding_model: 'text-embedding-3-small',
          embedding_options: {
            model: 'text-embedding-3-small',
            api_key: 'sk-placeholder',
            dimension: 4
          },
          vector_store: :in_memory,
          metadata_store: :in_memory,
          graph_store: :in_memory
        )
      )

      artifact = Woods::IndexArtifact.new(output_dir)
      dump_dir = artifact.new_dump_dir
      Woods::Storage::Snapshotter::Vector.dump(vs, artifact, dump_dir, resolved_config: resolved)
      Woods::Storage::Snapshotter::Metadata.dump(ms, artifact, dump_dir, resolved_config: resolved)
      artifact.write_config(resolved.to_snapshot_json)
      artifact.promote(dump_dir)
    end

    it 'raises MissingCredential when OPENAI_API_KEY is absent' do
      Dir.mktmpdir do |dir|
        write_openai_dump(dir)

        old_key = ENV.delete('OPENAI_API_KEY')
        begin
          expect do
            Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
          end.to raise_error(Woods::MCP::MissingCredential, /OPENAI_API_KEY/)
        ensure
          ENV['OPENAI_API_KEY'] = old_key if old_key
        end
      end
    end

    it 'succeeds (does not raise) when OPENAI_API_KEY is present' do
      Dir.mktmpdir do |dir|
        write_openai_dump(dir)

        old_key = ENV.delete('OPENAI_API_KEY')
        ENV['OPENAI_API_KEY'] = 'sk-test-key'
        begin
          # Provider will be unreachable (sk-test-key is invalid) →
          # ProviderUnreachable is caught internally and starts degraded.
          # No MissingCredential is raised.
          expect do
            Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
          end.not_to raise_error
        ensure
          ENV.delete('OPENAI_API_KEY')
          ENV['OPENAI_API_KEY'] = old_key if old_key
        end
      end
    end

    it 'boots with degraded state (not failed) when api key present but unreachable' do
      Dir.mktmpdir do |dir|
        write_openai_dump(dir)

        old_key = ENV.delete('OPENAI_API_KEY')
        ENV['OPENAI_API_KEY'] = 'sk-test-key'
        begin
          _retriever, state = Woods::MCP::Bootstrapper.build_retriever(index_dir: dir)
          expect(state.status).to eq(:degraded)
          expect(state.reason).to be_a(Woods::MCP::ProviderUnreachable)
        ensure
          ENV.delete('OPENAI_API_KEY')
          ENV['OPENAI_API_KEY'] = old_key if old_key
        end
      end
    end
  end
end
