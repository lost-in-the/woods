# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'woods'
require 'woods/embedding/indexer'
require 'woods/embedding/text_preparer'
require 'woods/embedding/provider'
require 'woods/storage/vector_store'

RSpec.describe Woods::Embedding::Indexer do
  # A small stub provider that returns deterministic vectors. Uses a real class
  # so the indexer exercises actual call paths instead of RSpec's message
  # tracking.
  let(:stub_provider_class) do
    Class.new do
      attr_reader :embed_batch_calls

      def initialize(vector: [0.1, 0.2])
        @vector = vector
        @embed_batch_calls = 0
      end

      def embed(_text)
        @vector
      end

      def embed_batch(texts)
        @embed_batch_calls += 1
        Array.new(texts.length) { @vector }
      end
    end
  end

  let(:output_dir) { '/tmp/claude/indexer_test' }
  let(:provider) { stub_provider_class.new }
  let(:text_preparer) { Woods::Embedding::TextPreparer.new }
  let(:vector_store) { Woods::Storage::VectorStore::InMemory.new }

  let(:indexer) do
    described_class.new(
      provider: provider,
      text_preparer: text_preparer,
      vector_store: vector_store,
      output_dir: output_dir,
      batch_size: 2
    )
  end

  let(:unit_data) do
    {
      'type' => 'model',
      'identifier' => 'User',
      'file_path' => 'app/models/user.rb',
      'namespace' => nil,
      'source_code' => "class User < ApplicationRecord\nend",
      'dependencies' => [],
      'chunks' => [],
      'source_hash' => 'abc123'
    }
  end

  let(:second_unit_data) do
    {
      'type' => 'service',
      'identifier' => 'PaymentService',
      'file_path' => 'app/services/payment_service.rb',
      'namespace' => nil,
      'source_code' => 'class PaymentService; end',
      'dependencies' => [],
      'chunks' => [],
      'source_hash' => 'def456'
    }
  end

  before do
    FileUtils.mkdir_p(output_dir)
    Dir.glob(File.join(output_dir, '*.json')).each { |f| File.delete(f) }
  end

  after do
    FileUtils.rm_rf(output_dir)
  end

  describe '#index_all' do
    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
    end

    it 'processes all units and returns stats' do
      stats = indexer.index_all
      expect(stats[:processed]).to eq(1)
      expect(stats[:skipped]).to eq(0)
      expect(stats[:errors]).to eq(0)
    end

    it 'stores the embedded vector in the vector store' do
      indexer.index_all

      expect(vector_store.count).to eq(1)
      results = vector_store.search([0.1, 0.2], limit: 1)
      expect(results.first.id).to eq('User')
      expect(results.first.metadata).to include(type: 'model', identifier: 'User')
    end

    it 'writes a checkpoint file keyed by identifier and source hash' do
      indexer.index_all

      checkpoint = JSON.parse(File.read(File.join(output_dir, 'checkpoint.json')))
      expect(checkpoint['User']).to eq('abc123')
    end

    context 'with multiple units' do
      before do
        File.write(File.join(output_dir, 'payment_service.json'), JSON.generate(second_unit_data))
      end

      it 'stores a vector for each unit' do
        stats = indexer.index_all

        expect(stats[:processed]).to eq(2)
        expect(vector_store.count).to eq(2)
      end
    end

    context 'with chunked units' do
      let(:chunked_data) do
        unit_data.merge(
          'chunks' => [
            { 'chunk_index' => 0, 'content' => 'chunk one content' },
            { 'chunk_index' => 1, 'content' => 'chunk two content' }
          ]
        )
      end

      before do
        File.write(File.join(output_dir, 'user.json'), JSON.generate(chunked_data))
      end

      it 'creates one embedding per chunk' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(2)
      end

      it 'stores each chunk under a chunk-suffixed id' do
        indexer.index_all

        stored_ids = vector_store.search([0.1, 0.2], limit: 10).map(&:id)
        expect(stored_ids).to contain_exactly('User#chunk_0', 'User#chunk_1')
      end
    end

    context 'with invalid JSON files' do
      before do
        File.write(File.join(output_dir, 'bad.json'), 'not valid json')
      end

      it 'skips invalid files gracefully' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(1)
      end
    end

    context 'when the checkpoint file already exists' do
      before do
        File.write(File.join(output_dir, 'checkpoint.json'), '{}')
      end

      it 'ignores checkpoint.json as a unit file' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(1)
      end
    end

    context 'when non-unit extraction output sits alongside unit files' do
      # Real extraction output has _index.json listings (arrays) plus manifest /
      # dependency_graph / graph_analysis summaries (hashes without a unit shape).
      # Prior to the shape filter, these parsed into build_unit and crashed with
      # TypeError: no implicit conversion of String into Integer.
      before do
        FileUtils.mkdir_p(File.join(output_dir, 'models'))
        File.write(File.join(output_dir, 'models', '_index.json'),
                   JSON.generate([{ 'identifier' => 'User', 'file_path' => 'app/models/user.rb' }]))
        File.write(File.join(output_dir, 'manifest.json'),
                   JSON.generate({ 'extracted_at' => '2026-04-22', 'unit_count' => 1 }))
        File.write(File.join(output_dir, 'dependency_graph.json'),
                   JSON.generate({ 'nodes' => [], 'edges' => [] }))
        File.write(File.join(output_dir, 'graph_analysis.json'),
                   JSON.generate({ 'orphans' => [], 'hubs' => [] }))
      end

      it 'processes only the unit file and ignores listings/summaries' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(1)
        expect(stats[:errors]).to eq(0)
      end
    end
  end

  # Regression — the Indexer accepted a +metadata_store:+ kwarg and persisted
  # it at end-of-run, but never wrote to it during embedding. The downstream
  # effect was that every vector-search hit in +codebase_retrieve+ missed on
  # the empty metadata store and ContextAssembler dropped every candidate to
  # nil, emitting "" with no error. See commit-message body for full context.
  describe 'metadata_store population' do
    let(:metadata_store) { Woods::Storage::MetadataStore::InMemory.new }

    let(:indexer_with_metadata) do
      described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: vector_store,
        metadata_store: metadata_store,
        output_dir: output_dir,
        batch_size: 2
      )
    end

    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
      File.write(File.join(output_dir, 'payment_service.json'), JSON.generate(second_unit_data))
    end

    it 'stores one metadata record per unit keyed by identifier' do
      indexer_with_metadata.index_all

      expect(metadata_store.count).to eq(2)
      expect(metadata_store.find('User')).to include('type' => 'model',
                                                     'file_path' => 'app/models/user.rb')
      expect(metadata_store.find('PaymentService')).to include('type' => 'service')
    end

    it 'preserves source_code so ContextAssembler#format_unit can render content' do
      indexer_with_metadata.index_all

      record = metadata_store.find('User')
      expect(record['source_code']).to include('class User')
    end

    it 'keys chunked units by the base identifier (not the #chunk_N id)' do
      chunked = unit_data.merge(
        'chunks' => [
          { 'chunk_index' => 0, 'content' => 'chunk one' },
          { 'chunk_index' => 1, 'content' => 'chunk two' }
        ]
      )
      File.write(File.join(output_dir, 'user.json'), JSON.generate(chunked))

      indexer_with_metadata.index_all

      expect(metadata_store.find('User')).not_to be_nil
      expect(metadata_store.find('User#chunk_0')).to be_nil
    end

    it 'is a no-op when metadata_store is nil (pre-persistence-arc hosts)' do
      nil_indexer = described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: vector_store,
        metadata_store: nil,
        output_dir: output_dir,
        batch_size: 2
      )

      expect { nil_indexer.index_all }.not_to raise_error
    end

    context 'in incremental mode' do
      before do
        File.write(File.join(output_dir, 'checkpoint.json'),
                   JSON.generate('User' => 'abc123', 'PaymentService' => 'stale'))
      end

      it 'repopulates metadata for units whose embedding is skipped' do
        # The checkpoint says User is unchanged — embedding skips it — but
        # the metadata store is a fresh empty in-memory store this run, so
        # metadata must still be written or retrieval sees a void.
        indexer_with_metadata.index_incremental

        expect(metadata_store.find('User')).not_to be_nil
        expect(metadata_store.find('PaymentService')).not_to be_nil
      end
    end
  end

  describe '#index_incremental' do
    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
    end

    context 'when no checkpoint exists' do
      it 'processes all units' do
        stats = indexer.index_incremental
        expect(stats[:processed]).to eq(1)
        expect(stats[:skipped]).to eq(0)
      end
    end

    context 'when checkpoint matches current hash' do
      before do
        checkpoint = { 'User' => 'abc123' }
        File.write(File.join(output_dir, 'checkpoint.json'), JSON.generate(checkpoint))
      end

      it 'skips unchanged units and does not embed them' do
        stats = indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(stats[:skipped]).to eq(1)
        expect(provider.embed_batch_calls).to eq(0)
        expect(vector_store.count).to eq(0)
      end
    end

    context 'when checkpoint has a different hash' do
      before do
        checkpoint = { 'User' => 'old_hash' }
        File.write(File.join(output_dir, 'checkpoint.json'), JSON.generate(checkpoint))
      end

      it 'processes the changed unit' do
        stats = indexer.index_incremental

        expect(stats[:processed]).to eq(1)
        expect(stats[:skipped]).to eq(0)
        expect(vector_store.count).to eq(1)
      end
    end

    context 'with corrupted checkpoint file' do
      before do
        File.write(File.join(output_dir, 'checkpoint.json'), 'not json')
      end

      it 'treats all units as new' do
        stats = indexer.index_incremental
        expect(stats[:processed]).to eq(1)
      end
    end
  end

  describe 'error handling' do
    # Provider that always fails — a behavioural stub, not a mock spy.
    let(:failing_provider_class) do
      Class.new do
        def initialize(message)
          @message = message
        end

        def embed(_text)
          raise StandardError, @message
        end

        def embed_batch(_texts)
          raise StandardError, @message
        end
      end
    end

    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
    end

    it 'raises Woods::Error on provider failure' do
      failing_indexer = described_class.new(
        provider: failing_provider_class.new('connection refused'),
        text_preparer: text_preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        batch_size: 2
      )

      expect { failing_indexer.index_all }.to raise_error(
        Woods::Error, /Embedding failed: connection refused/
      )
    end

    it 'increments error count in stats via embed_and_store' do
      failing_indexer = described_class.new(
        provider: failing_provider_class.new('network timeout'),
        text_preparer: text_preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        batch_size: 2
      )

      stats = { processed: 0, skipped: 0, errors: 0 }
      items = [{ id: 'User', text: 'class User; end', unit_data: unit_data,
                 source_hash: 'abc123', identifier: 'User' }]
      checkpoint = {}

      expect do
        failing_indexer.send(:embed_and_store, items, checkpoint, stats)
      end.to raise_error(Woods::Error, /network timeout/)

      expect(stats[:errors]).to eq(1)
    end
  end

  describe 'empty output directory' do
    it 'returns zero stats when no files exist' do
      stats = indexer.index_all
      expect(stats).to eq({ processed: 0, skipped: 0, errors: 0 })
    end
  end

  # Regression — Ollama rejects inputs over its num_ctx (default 2048,
  # we configure 8192). Without auto-chunking, real-world services with
  # >~20 KB of source hit "400 the input length exceeds the context
  # length" and the whole embed run aborts. The Indexer must chunk
  # oversize units before sending them to the provider.
  describe 'auto-chunking for oversize units' do
    let(:budget_provider_class) do
      Class.new(stub_provider_class) do
        def max_input_tokens
          8192
        end
      end
    end

    let(:nomic_preparer) do
      Woods::Embedding::TextPreparer.new(max_tokens: 8192, chars_per_token: 2.5)
    end

    let(:provider) { budget_provider_class.new }
    let(:text_preparer) { nomic_preparer }

    let(:chunker) { Woods::Chunking::SemanticChunker.new(threshold: 10, max_chars: 20_000) }

    let(:indexer) do
      described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        chunker: chunker,
        batch_size: 4
      )
    end

    let(:huge_service) do
      body = (['    work_on(item)'] * 4000).join("\n")
      {
        'type' => 'service',
        'identifier' => 'BigService',
        'file_path' => 'app/services/big_service.rb',
        'namespace' => nil,
        'source_code' => "class BigService\n  def call(item)\n#{body}\n  end\n  def other; :ok; end\nend",
        'dependencies' => [],
        'chunks' => [],
        'source_hash' => 'big123'
      }
    end

    before do
      File.write(File.join(output_dir, 'big_service.json'), JSON.generate(huge_service))
    end

    it 'splits oversize units into multiple embeddings' do
      stats = indexer.index_all
      expect(stats[:processed]).to be > 1
    end

    it 'stores each chunk under a #chunk_N id' do
      indexer.index_all
      ids = vector_store.search([0.1, 0.2], limit: 100).map(&:id)
      expect(ids).to all(match(/\ABigService#chunk_\d+\z/))
    end

    it 'respects the provider char budget on every embedded text' do
      recorded_texts = []
      allow(provider).to receive(:embed_batch).and_wrap_original do |orig, texts|
        recorded_texts.concat(texts)
        orig.call(texts)
      end

      indexer.index_all
      budget = 8192 * 2.5
      expect(recorded_texts).to all(satisfy { |t| t.length <= budget })
    end

    it 'skips chunking when the provider advertises no budget' do
      no_budget_provider = stub_provider_class.new # no max_input_tokens method
      small_indexer = described_class.new(
        provider: no_budget_provider,
        text_preparer: text_preparer,
        vector_store: vector_store,
        output_dir: output_dir,
        chunker: chunker,
        batch_size: 4
      )
      stats = small_indexer.index_all
      # Provider without a budget => no auto-chunking, unit goes whole.
      expect(stats[:processed]).to eq(1)
    end

    # Regression — `rails_source` units arrive from extraction with
    # `chunks` already populated. Those chunks are not sized against
    # the embedding provider's budget, so the Indexer must re-enforce
    # the chunker's max_chars ceiling on them before sending. Prior
    # to this the oversize pre-existing chunk hit Ollama unchanged and
    # produced `400 the input length exceeds the context length`.
    it 'splits oversize pre-existing chunks so none exceed the char budget' do
      huge_line = 'x' * 30_000
      pre_chunked_unit = {
        'type' => 'rails_source',
        'identifier' => 'Rails::Big',
        'file_path' => '/gems/rails/big.rb',
        'namespace' => nil,
        'source_code' => 'class Big; end',
        'dependencies' => [],
        'chunks' => [{ 'content' => huge_line, 'chunk_type' => 'section' }],
        'source_hash' => 'rails123'
      }
      File.write(File.join(output_dir, 'rails_big.json'), JSON.generate(pre_chunked_unit))

      recorded_texts = []
      allow(provider).to receive(:embed_batch).and_wrap_original do |orig, texts|
        recorded_texts.concat(texts)
        orig.call(texts)
      end

      indexer.index_all
      budget = 8192 * 2.5
      expect(recorded_texts).to all(satisfy { |t| t.length <= budget })
    end
  end

  # Persistence is activated only when the vector store responds to #each_entry
  # and #bulk_load (the in-memory seam). Snapshotter::Vector and ::Metadata are
  # in-flight work from other teammates; we use instance_doubles so these specs
  # don't depend on their real implementations landing first.
  describe 'persistence after index_all' do
    require 'woods/index_artifact'
    require 'woods/storage/snapshotter'

    let(:persistable_store) do
      store = Woods::Storage::VectorStore::InMemory.new
      allow(store).to receive(:each_entry).and_yield('User', [0.1, 0.2], { type: 'model' })
      allow(store).to receive(:bulk_load)
      store
    end

    # Snapshotters are modules whose implementations land in a parallel PR.
    # Use plain doubles so these specs don't depend on the real implementations.
    let(:vector_snapshotter) { double('Snapshotter::Vector') }
    let(:metadata_snapshotter) { double('Snapshotter::Metadata') }

    let(:resolved_config) do
      double('ResolvedConfig',
             to_snapshot_json: { 'schema_version' => 1, 'gem_version' => '0.0.1',
                                 'created_at' => '2026-04-22T00:00:00Z',
                                 'embedding_provider' => {}, 'stores' => {} })
    end

    let(:persistent_indexer) do
      described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: persistable_store,
        output_dir: output_dir,
        batch_size: 2,
        metadata_store: nil,
        resolved_config: resolved_config,
        dump_retention_count: 3
      )
    end

    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
    end

    it 'calls Snapshotter::Vector.dump with the store and a dump_dir under dumps/' do
      stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
      stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)

      expect(vector_snapshotter).to receive(:dump) do |store, _artifact, dump_dir|
        expect(store).to eq(persistable_store)
        expect(dump_dir.to_s).to include('dumps')
      end

      persistent_indexer.index_all
    end

    it 'writes woods.json to output_dir after a successful run' do
      stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
      stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
      allow(vector_snapshotter).to receive(:dump)

      persistent_indexer.index_all

      config_path = File.join(output_dir, 'woods.json')
      expect(File.exist?(config_path)).to be true
      parsed = JSON.parse(File.read(config_path))
      expect(parsed['schema_version']).to eq(1)
    end

    it 'flips the latest pointer after a successful run' do
      stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
      stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
      allow(vector_snapshotter).to receive(:dump)

      persistent_indexer.index_all

      latest_path = File.join(output_dir, 'dumps', 'latest')
      expect(File.exist?(latest_path)).to be true
      latest = File.read(latest_path).strip
      expect(latest).not_to be_empty
      expect(File.directory?(File.join(output_dir, 'dumps', latest))).to be true
    end

    it 'does not call Snapshotter for metadata when metadata_store is nil' do
      stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
      stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
      allow(vector_snapshotter).to receive(:dump)

      expect(metadata_snapshotter).not_to receive(:dump)

      persistent_indexer.index_all
    end

    context 'when metadata_store is provided and supports the seam' do
      let(:persistable_metadata_store) do
        store = double('MetadataStore::InMemory')
        allow(store).to receive(:each_entry)
        allow(store).to receive(:bulk_load)
        allow(store).to receive(:store) # called by persist_unit_metadata
        store
      end

      let(:indexer_with_metadata) do
        described_class.new(
          provider: provider,
          text_preparer: text_preparer,
          vector_store: persistable_store,
          output_dir: output_dir,
          batch_size: 2,
          metadata_store: persistable_metadata_store,
          resolved_config: resolved_config,
          dump_retention_count: 3
        )
      end

      it 'calls Snapshotter::Metadata.dump when metadata_store has the seam' do
        stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
        stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
        allow(vector_snapshotter).to receive(:dump)

        expect(metadata_snapshotter).to receive(:dump) do |store, _artifact, dump_dir|
          expect(store).to eq(persistable_metadata_store)
          expect(dump_dir.to_s).to include('dumps')
        end

        indexer_with_metadata.index_all
      end
    end

    context 'when vector_store does not support the persistence seam' do
      let(:non_persistable_store) do
        double('SomeExternalStore')
        # does NOT respond to each_entry / bulk_load
      end

      let(:non_persistent_indexer) do
        described_class.new(
          provider: provider,
          text_preparer: text_preparer,
          vector_store: non_persistable_store,
          output_dir: output_dir,
          batch_size: 2,
          resolved_config: resolved_config,
          dump_retention_count: 3
        )
      end

      before do
        allow(non_persistable_store).to receive(:store_batch)
      end

      it 'does not attempt persistence' do
        stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
        expect(vector_snapshotter).not_to receive(:dump)

        non_persistent_indexer.index_all
      end

      it 'does not write woods.json' do
        stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)

        non_persistent_indexer.index_all

        expect(File.exist?(File.join(output_dir, 'woods.json'))).to be false
      end
    end

    context 'dump retention' do
      let(:indexer_with_retention) do
        described_class.new(
          provider: provider,
          text_preparer: text_preparer,
          vector_store: persistable_store,
          output_dir: output_dir,
          batch_size: 2,
          resolved_config: resolved_config,
          dump_retention_count: 2
        )
      end

      it 'prunes old dump directories beyond the retention count' do
        stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
        stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
        allow(vector_snapshotter).to receive(:dump)

        dumps_dir = File.join(output_dir, 'dumps')
        FileUtils.mkdir_p(dumps_dir)

        # Pre-create two old dump directories with earlier timestamps
        old_dirs = %w[2026-04-20T00-00-00Z 2026-04-21T00-00-00Z].map do |name|
          dir = File.join(dumps_dir, name)
          FileUtils.mkdir_p(dir)
          dir
        end

        indexer_with_retention.index_all

        # After index_all with retention 2, the new dump is kept plus one old one
        remaining = Dir.glob(File.join(dumps_dir, '*/'))
                       .map { |d| File.basename(d.chomp('/')) }
                       .reject { |n| n == 'latest' }

        expect(remaining.length).to eq(2)
        # The oldest directory should have been pruned
        expect(File.exist?(old_dirs.first)).to be false
      end
    end
  end

  describe 'dump_retention_count default' do
    it 'defaults to 3' do
      idx = described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: vector_store,
        output_dir: output_dir
      )
      expect(idx.instance_variable_get(:@dump_retention_count)).to eq(3)
    end
  end

  describe 'dump retention boundary: zero and nil disable pruning' do
    # dump_retention_count = 0 or nil must leave all existing dump directories intact.
    # The prune_old_dumps method guards on `nil? || <= 0` before touching anything.

    require 'woods/index_artifact'
    require 'woods/storage/snapshotter'

    let(:persistable_store) do
      store = Woods::Storage::VectorStore::InMemory.new
      allow(store).to receive(:each_entry).and_return([])
      allow(store).to receive(:bulk_load)
      store
    end

    let(:vector_snapshotter) { double('Snapshotter::Vector') }
    let(:metadata_snapshotter) { double('Snapshotter::Metadata') }

    let(:resolved_config) do
      double('ResolvedConfig',
             to_snapshot_json: { 'schema_version' => 1, 'gem_version' => '0.0.1',
                                 'created_at' => '2026-04-22T00:00:00Z',
                                 'embedding_provider' => {}, 'stores' => {} })
    end

    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
      stub_const('Woods::Storage::Snapshotter::Vector', vector_snapshotter)
      stub_const('Woods::Storage::Snapshotter::Metadata', metadata_snapshotter)
      allow(vector_snapshotter).to receive(:dump)
    end

    def pre_create_dump_dirs(count)
      dumps_dir = File.join(output_dir, 'dumps')
      FileUtils.mkdir_p(dumps_dir)
      (1..count).map do |i|
        name = format('2026-04-%02dT00-00-00Z', i)
        dir = File.join(dumps_dir, name)
        FileUtils.mkdir_p(dir)
        dir
      end
    end

    context 'when dump_retention_count = 0' do
      let(:indexer_zero_retention) do
        described_class.new(
          provider: provider,
          text_preparer: text_preparer,
          vector_store: persistable_store,
          output_dir: output_dir,
          batch_size: 2,
          resolved_config: resolved_config,
          dump_retention_count: 0
        )
      end

      it 'keeps all existing dump directories (5 pre-existing + 1 new = 6 total)' do
        old_dirs = pre_create_dump_dirs(5)

        indexer_zero_retention.index_all

        remaining = Dir.glob(File.join(output_dir, 'dumps', '*/'))
                       .map { |d| File.basename(d.chomp('/')) }
                       .reject { |n| n == 'latest' }

        expect(remaining.length).to eq(6) # 5 old + 1 created by index_all
        old_dirs.each { |dir| expect(File.exist?(dir)).to be true }
      end
    end

    context 'when dump_retention_count = nil' do
      let(:indexer_nil_retention) do
        described_class.new(
          provider: provider,
          text_preparer: text_preparer,
          vector_store: persistable_store,
          output_dir: output_dir,
          batch_size: 2,
          resolved_config: resolved_config,
          dump_retention_count: nil
        )
      end

      it 'keeps all existing dump directories (5 pre-existing + 1 new = 6 total)' do
        old_dirs = pre_create_dump_dirs(5)

        indexer_nil_retention.index_all

        remaining = Dir.glob(File.join(output_dir, 'dumps', '*/'))
                       .map { |d| File.basename(d.chomp('/')) }
                       .reject { |n| n == 'latest' }

        expect(remaining.length).to eq(6) # 5 old + 1 created by index_all
        old_dirs.each { |dir| expect(File.exist?(dir)).to be true }
      end
    end
  end
end
