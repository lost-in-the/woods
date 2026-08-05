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

    context 'when a unit file contains non-ASCII bytes' do
      # Regression — B-077 / #189. load_units read unit JSON with a bare
      # File.read, which tags the bytes with the process's default external
      # encoding — US-ASCII under LANG=C, which is exactly how this suite
      # runs — so the first multibyte character (an accent, an em dash)
      # raised Encoding::InvalidByteSequenceError out of JSON.parse and
      # aborted the whole woods:embed run instead of anything per-unit.
      let(:accented_unit) do
        unit_data.merge(
          'identifier' => 'Café',
          'file_path' => 'app/models/café.rb',
          'source_code' => "class Café < ApplicationRecord\n  # naïve ordering — see notes\nend",
          'source_hash' => 'cafe123'
        )
      end

      before do
        Woods::AtomicFile.write(File.join(output_dir, 'cafe.json'), JSON.generate(accented_unit))
      end

      it 'embeds the unit instead of raising' do
        stats = indexer.index_all

        expect(stats[:processed]).to eq(2)
        expect(stats[:errors]).to eq(0)
      end

      it 'round-trips the non-ASCII identifier through checkpoint.json' do
        # Covers the whole loop: load_units (AtomicFile.read of the unit),
        # save_checkpoint (now AtomicFile.write — atomic, binmode) and
        # load_checkpoint-compatible bytes on disk.
        indexer.index_all

        checkpoint = JSON.parse(Woods::AtomicFile.read(File.join(output_dir, 'checkpoint.json')))
        expect(checkpoint['Café']).to eq('cafe123')
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

    it 'keys chunked units by the base identifier (the ContextAssembler collapses #chunk_N ids)' do
      # The Indexer stores under the base identifier; the vector store still
      # stores per-chunk entries (User#chunk_0, User#chunk_1). Retrieval
      # normalises chunk ids back to the base before metadata lookup — see
      # Woods::Retrieval::ContextAssembler#collapse_chunk_candidates.
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
        # A previous run's dump is what makes a checkpoint hit honourable —
        # without one the Indexer re-embeds rather than trusting the
        # checkpoint (see 'incremental persistence' below). Run a full pass
        # through its own indexer so this example's metadata store starts
        # empty, which is the point of the assertion.
        described_class.new(
          provider: provider, text_preparer: text_preparer,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          output_dir: output_dir, batch_size: 2
        ).index_all

        File.write(File.join(output_dir, 'checkpoint.json'),
                   JSON.generate('User' => 'abc123', 'PaymentService' => 'stale'))
      end

      it 'repopulates metadata for units whose embedding is skipped' do
        # The checkpoint says User is unchanged — embedding skips it — but
        # the metadata store is a fresh empty in-memory store this run, so
        # metadata must still be written or retrieval sees a void.
        stats = indexer_with_metadata.index_incremental

        expect(stats[:skipped]).to eq(1)
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

    context 'when checkpoint matches current hash and a dump holds the vector' do
      before do
        # The consistent world: a previous full run left both a dump and a
        # checkpoint. `indexer` hydrates from that dump, so the checkpoint hit
        # is honourable and nothing is re-embedded.
        described_class.new(
          provider: provider, text_preparer: text_preparer,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          output_dir: output_dir, batch_size: 2
        ).index_all
      end

      it 'skips unchanged units and does not embed them' do
        embed_calls_before = provider.embed_batch_calls

        stats = indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(stats[:skipped]).to eq(1)
        expect(provider.embed_batch_calls).to eq(embed_calls_before)
        # Hydrated from the dump rather than embedded — the vector is still
        # there for the dump this run writes.
        expect(vector_store.count).to eq(1)
      end
    end

    context 'when the checkpoint matches but no durable dump holds the vector' do
      before do
        File.write(File.join(output_dir, 'checkpoint.json'), JSON.generate('User' => 'abc123'))
      end

      it 'ignores the checkpoint and embeds the unit anyway' do
        # B-059 / #148 — honouring this checkpoint would write a dump missing
        # User's vector while leaving the checkpoint claiming it is done, and
        # no later incremental run would ever produce it.
        allow(indexer).to receive(:warn)

        stats = indexer.index_incremental

        expect(stats[:processed]).to eq(1)
        expect(stats[:skipped]).to eq(0)
        expect(vector_store.count).to eq(1)
      end

      it 'warns that the checkpoint had advanced past the durable artifact' do
        allow(indexer).to receive(:warn)

        indexer.index_incremental

        expect(indexer).to have_received(:warn).with(/checkpoint had advanced past/)
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

    context 'when the checkpoint contains non-ASCII bytes' do
      # Regression — B-077 / #189. load_checkpoint's bare File.read made
      # JSON.parse raise EncodingError (not JSON::ParserError, the only class
      # rescued) under a US-ASCII default external encoding, aborting the run.
      # The full fix must *parse* the checkpoint, not merely rescue it into
      # {} — hence the skipped-unit assertion: a degraded-to-empty checkpoint
      # would re-embed User instead of skipping it.
      before do
        described_class.new(
          provider: provider, text_preparer: text_preparer,
          vector_store: Woods::Storage::VectorStore::InMemory.new,
          output_dir: output_dir, batch_size: 2
        ).index_all

        checkpoint = JSON.parse(Woods::AtomicFile.read(File.join(output_dir, 'checkpoint.json')))
        Woods::AtomicFile.write(File.join(output_dir, 'checkpoint.json'),
                                JSON.generate(checkpoint.merge('Café' => 'naïve')))
      end

      it 'honours the checkpoint instead of raising or degrading to a re-embed' do
        stats = indexer.index_incremental

        expect(stats[:skipped]).to eq(1)
        expect(stats[:processed]).to eq(0)
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

  # Regression — B-059 / #148. On the :local and :shared_filesystem presets the
  # vector store is in-memory and the *dump* is the only durable copy. Every
  # `rake woods:embed_incremental` builds a fresh empty store (see
  # Woods::Tasks.build_embed_indexer), so unless the incremental run hydrates
  # from the latest dump and dumps again, the vectors it embeds live and die
  # inside that one process — while checkpoint.json advances over them, so no
  # later incremental run will ever produce them again.
  #
  # These specs use the real Snapshotter and IndexArtifact deliberately: the
  # failure is in the interaction between the checkpoint file and the on-disk
  # dump, and doubles would hide it.
  describe 'incremental persistence' do
    require 'woods/index_artifact'
    require 'woods/storage/snapshotter'

    let(:resolved_config) do
      double('ResolvedConfig',
             model_name: 'stub-embed',
             to_snapshot_json: { 'schema_version' => 1, 'gem_version' => '0.0.1',
                                 'created_at' => '2026-04-22T00:00:00Z',
                                 'embedding_provider' => {}, 'stores' => {} })
    end

    # A new store per indexer — this is what a separate `rake` process gets.
    def fresh_indexer
      described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: Woods::Storage::VectorStore::InMemory.new,
        metadata_store: Woods::Storage::MetadataStore::InMemory.new,
        output_dir: output_dir,
        batch_size: 2,
        resolved_config: resolved_config
      )
    end

    # Ids durably readable from the promoted dump — i.e. what a fresh
    # woods-mcp boot would actually see.
    def persisted_vector_ids
      artifact = Woods::IndexArtifact.new(output_dir)
      Woods::Storage::Snapshotter::Vector.load_or_empty(artifact).each_entry.map { |id, _v, _m| id }
    end

    def checkpoint_on_disk
      JSON.parse(File.read(File.join(output_dir, 'checkpoint.json')))
    end

    # The vanished-unit sweep sits behind a 30% purge guard (B-079 / #191),
    # so specs exercising a *genuine* small deletion need enough persisted
    # units for one deletion to stay at or under the threshold.
    def write_filler_units(count)
      (1..count).each do |i|
        File.write(File.join(output_dir, "filler_#{i}.json"),
                   JSON.generate(unit_data.merge('identifier' => "Filler#{i}",
                                                 'file_path' => "app/models/filler_#{i}.rb",
                                                 'source_hash' => "filler#{i}")))
      end
    end

    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
      fresh_indexer.index_all
      # A unit the full run never saw — the incremental run's only work.
      File.write(File.join(output_dir, 'payment_service.json'), JSON.generate(second_unit_data))
    end

    # A dump is a whole-store snapshot, so writing one for a run that embedded
    # nothing produces byte-identical content AND rotates the retention window —
    # three no-op runs would evict every genuinely older dump in favour of
    # copies of the same state.
    it 'writes no new dump for an incremental run that embedded nothing' do
      fresh_indexer.index_incremental # consumes the pending unit
      dumps = Woods::IndexArtifact.new(output_dir).dumps_root
      before = Dir.children(dumps).sort

      stats = fresh_indexer.index_incremental

      expect(stats[:processed]).to eq(0)
      expect(Dir.children(dumps).sort).to eq(before)
    end

    # B-069: the dump gate skipped persist_snapshot on processed==0, which also
    # froze metadata.msgpack — so a deleted unit kept both its stale vector AND
    # its metadata, taking the vector from inert to retrievable. Deleting a unit
    # changes no other unit's source_hash, so processed stays 0 and only the
    # vanished-unit check can notice.
    it 'rewrites the dump when a unit vanished from the index, even with nothing embedded' do
      write_filler_units(2) # 4 persisted units, so 1 deletion stays under the purge guard
      fresh_indexer.index_incremental # consume the pending units
      File.delete(File.join(output_dir, 'payment_service.json'))

      stats = fresh_indexer.index_incremental

      expect(stats[:processed]).to eq(0)
      expect(persisted_vector_ids).to contain_exactly('User', 'Filler1', 'Filler2')
    end

    it 'drops the vanished unit from the metadata dump as well as the vectors' do
      write_filler_units(2) # 4 persisted units, so 1 deletion stays under the purge guard
      fresh_indexer.index_incremental
      File.delete(File.join(output_dir, 'payment_service.json'))

      fresh_indexer.index_incremental

      metadata = Woods::Storage::Snapshotter::Metadata.load_or_empty(
        Woods::IndexArtifact.new(output_dir)
      )
      expect(metadata.find('PaymentService')).to be_nil
      expect(metadata.find('User')).not_to be_nil
    end

    it 'still leaves the previously persisted vectors readable after a no-op run' do
      fresh_indexer.index_incremental
      fresh_indexer.index_incremental

      expect(persisted_vector_ids).to contain_exactly('User', 'PaymentService')
    end

    it 'persists the newly embedded unit into the promoted dump' do
      stats = fresh_indexer.index_incremental

      expect(stats[:processed]).to eq(1)
      expect(persisted_vector_ids).to include('PaymentService')
    end

    it 'keeps the previously embedded units in the dump it writes' do
      fresh_indexer.index_incremental

      expect(persisted_vector_ids).to include('User')
    end

    it 'does not advance the checkpoint over a unit no durable store holds' do
      # The unrecoverability proof: whatever this run decided, a following
      # incremental run must not skip a unit that is absent from the dump.
      fresh_indexer.index_incremental

      second_run = fresh_indexer
      second_run.index_incremental

      expect(persisted_vector_ids).to include('PaymentService')
      expect(checkpoint_on_disk['PaymentService']).to eq('def456')
    end

    it 're-embeds a unit the checkpoint claims but the dump does not hold' do
      # Simulates a checkpoint that ran ahead of the durable artifact for any
      # reason (an interrupted dump, a store swap, this very bug in an older
      # gem version). Trusting it would strand the unit forever.
      File.write(File.join(output_dir, 'checkpoint.json'),
                 JSON.generate('User' => 'abc123', 'PaymentService' => 'def456'))

      indexer = fresh_indexer
      allow(indexer).to receive(:warn)

      stats = indexer.index_incremental

      expect(stats[:processed]).to eq(1)
      expect(persisted_vector_ids).to include('PaymentService')
    end

    it 'drops chunk ids a re-embedded unit no longer produces' do
      chunked = lambda do |count, hash|
        unit_data.merge(
          'source_hash' => hash,
          'chunks' => Array.new(count) { |i| { 'chunk_index' => i, 'content' => "chunk #{i} content" } }
        )
      end

      File.write(File.join(output_dir, 'user.json'), JSON.generate(chunked.call(3, 'three')))
      fresh_indexer.index_all
      expect(persisted_vector_ids).to include('User#chunk_2')

      File.write(File.join(output_dir, 'user.json'), JSON.generate(chunked.call(2, 'two')))
      fresh_indexer.index_incremental

      expect(persisted_vector_ids).to include('User#chunk_0', 'User#chunk_1')
      expect(persisted_vector_ids).not_to include('User#chunk_2')
    end

    context 'when a unit has a non-ASCII identifier' do
      # Regression — B-080 / #192. Snapshotter::Vector's parse_idx built ids
      # with byteslice on a binread buffer, so hydrated ids came back tagged
      # ASCII-8BIT. A non-ASCII identifier is not eql? to its UTF-8 twin, so
      # @persisted_ids.key?('Café') missed — the checkpoint self-heal
      # re-embedded the unit on every incremental run forever — and the
      # InMemory store's id_to_index lookup missed too, appending a second
      # live entry per run (doubling counts and search results). Complements
      # the index_all 'Café' round-trip above, which never hydrates a dump.
      let(:cafe_unit) do
        unit_data.merge('identifier' => 'Café',
                        'file_path' => 'app/models/café.rb',
                        'source_hash' => 'cafe123')
      end

      before do
        File.delete(File.join(output_dir, 'payment_service.json'))
        Woods::AtomicFile.write(File.join(output_dir, 'cafe.json'), JSON.generate(cafe_unit))
        fresh_indexer.index_incremental # embeds Café and promotes a dump holding it
      end

      it 'skips the unchanged unit instead of re-embedding it every run' do
        embed_calls_before = provider.embed_batch_calls

        stats = fresh_indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(stats[:skipped]).to eq(2) # User + Café
        expect(provider.embed_batch_calls).to eq(embed_calls_before)
      end

      it 'holds exactly one live store entry for the identifier after hydration' do
        store = Woods::Storage::VectorStore::InMemory.new
        indexer = described_class.new(
          provider: provider, text_preparer: text_preparer,
          vector_store: store,
          metadata_store: Woods::Storage::MetadataStore::InMemory.new,
          output_dir: output_dir, batch_size: 2, resolved_config: resolved_config
        )

        indexer.index_incremental

        # Count by bytes so a duplicate under a different encoding tag is
        # caught, then assert full equality — encoding included.
        cafe_entries = store.each_entry.select { |id, _v, _m| id.b == 'Café'.b }
        expect(cafe_entries.length).to eq(1)
        expect(cafe_entries.first.first).to eq('Café')
      end
    end

    it 'falls back to a complete re-embed when the latest dump cannot be read' do
      dump_dir = File.join(output_dir, 'dumps', File.read(File.join(output_dir, 'dumps', 'latest')).strip)
      File.binwrite(File.join(dump_dir, 'vectors.bin'), 'garbage')

      indexer = fresh_indexer
      allow(indexer).to receive(:warn)

      stats = indexer.index_incremental

      expect(stats[:processed]).to eq(2)
      expect(persisted_vector_ids).to include('User', 'PaymentService')
      expect(indexer).to have_received(:warn).with(/could not hydrate vectors/)
    end

    it 'leaves the checkpoint untouched when the dump cannot be written' do
      allow(Woods::Storage::Snapshotter::Vector).to receive(:dump)
        .and_raise(Errno::ENOSPC, 'dumps')

      before_checkpoint = checkpoint_on_disk

      expect { fresh_indexer.index_incremental }.to raise_error(Errno::ENOSPC)
      expect(checkpoint_on_disk).to eq(before_checkpoint)
      expect(checkpoint_on_disk).not_to have_key('PaymentService')
    end

    it 'writes no interval checkpoint for batches that only exist in memory' do
      # checkpoint_interval saves are the same failure mode in miniature: a
      # batch stored into an in-memory store is not durable until the dump is
      # promoted, so a crash later in the run must not leave the checkpoint
      # claiming the earlier batches.
      one_shot_provider = Class.new do
        def initialize
          @calls = 0
        end

        def embed_batch(texts)
          @calls += 1
          raise StandardError, 'provider died' if @calls > 1

          Array.new(texts.length) { [0.1, 0.2] }
        end
      end.new

      File.write(File.join(output_dir, 'third.json'),
                 JSON.generate(second_unit_data.merge('identifier' => 'Third', 'source_hash' => 'ghi789')))

      indexer = described_class.new(
        provider: one_shot_provider, text_preparer: text_preparer,
        vector_store: Woods::Storage::VectorStore::InMemory.new,
        output_dir: output_dir, batch_size: 1, checkpoint_interval: 1,
        resolved_config: resolved_config
      )

      before_checkpoint = checkpoint_on_disk

      expect { indexer.index_incremental }.to raise_error(Woods::Error, /provider died/)
      expect(checkpoint_on_disk).to eq(before_checkpoint)
    end
  end

  # Regression — B-079 / #191. "Vanished" is computed as persisted-minus-
  # current, so an incremental run that loads zero unit JSONs (mismatched
  # WOODS_OUTPUT between shells, deleted extraction output, a glob failure)
  # reads as "every unit vanished": drop_vanished_units pruned every vector
  # and persist_snapshot promoted an effectively empty dump — and with
  # retention 3, two more such runs evicted every dump that held real data.
  # The gem's other destructive sweeps (Obsidian, Unblocked) sit behind a
  # 30% purge guard; the vanished-unit sweep now has the same guard, with
  # WOODS_ALLOW_PURGE=1 as the explicit override.
  describe 'vanished-unit purge guard' do
    require 'woods/index_artifact'
    require 'woods/storage/snapshotter'

    let(:resolved_config) do
      double('ResolvedConfig',
             model_name: 'stub-embed',
             to_snapshot_json: { 'schema_version' => 1, 'gem_version' => '0.0.1',
                                 'created_at' => '2026-04-22T00:00:00Z',
                                 'embedding_provider' => {}, 'stores' => {} })
    end

    let(:all_identifiers) { %w[User PaymentService Order Invoice] }

    def fresh_indexer
      described_class.new(
        provider: provider,
        text_preparer: text_preparer,
        vector_store: Woods::Storage::VectorStore::InMemory.new,
        metadata_store: Woods::Storage::MetadataStore::InMemory.new,
        output_dir: output_dir,
        batch_size: 2,
        resolved_config: resolved_config
      )
    end

    def guarded_indexer
      indexer = fresh_indexer
      allow(indexer).to receive(:warn)
      indexer
    end

    def persisted_vector_ids
      artifact = Woods::IndexArtifact.new(output_dir)
      Woods::Storage::Snapshotter::Vector.load_or_empty(artifact).each_entry.map { |id, _v, _m| id }
    end

    def dump_dir_names
      Dir.children(File.join(output_dir, 'dumps')).sort
    end

    def delete_unit_files(*identifiers)
      identifiers.each { |name| File.delete(File.join(output_dir, "#{name.downcase}.json")) }
    end

    before do
      all_identifiers.each do |name|
        File.write(File.join(output_dir, "#{name.downcase}.json"),
                   JSON.generate(unit_data.merge('identifier' => name,
                                                 'file_path' => "app/models/#{name.downcase}.rb",
                                                 'source_hash' => "hash-#{name}")))
      end
      fresh_indexer.index_all # promote a dump holding all four units
    end

    context 'when the run loads no units at all' do
      before { delete_unit_files(*all_identifiers) }

      it 'refuses the prune and keeps every persisted vector' do
        stats = guarded_indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(persisted_vector_ids).to match_array(all_identifiers)
      end

      it 'writes no dump, so the retention window is not rotated' do
        before_dumps = dump_dir_names

        guarded_indexer.index_incremental

        expect(dump_dir_names).to eq(before_dumps)
      end

      it 'warns before deleting anything, naming the override' do
        indexer = guarded_indexer

        indexer.index_incremental

        expect(indexer).to have_received(:warn)
          .with(/nothing loaded.*refusing to prune 4 persisted.*WOODS_ALLOW_PURGE=1/m)
      end

      context 'with WOODS_ALLOW_PURGE=1' do
        before { ENV['WOODS_ALLOW_PURGE'] = '1' }
        after { ENV.delete('WOODS_ALLOW_PURGE') }

        it 'prunes everything and promotes the (empty) dump' do
          guarded_indexer.index_incremental

          expect(persisted_vector_ids).to be_empty
        end
      end
    end

    context 'when more than 30% of the persisted units vanished' do
      before { delete_unit_files('PaymentService', 'Order') } # 2 of 4 = 50%

      it 'refuses the prune and keeps every persisted vector' do
        stats = guarded_indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(persisted_vector_ids).to match_array(all_identifiers)
      end

      it 'warns with the vanished/persisted counts and the override' do
        indexer = guarded_indexer

        indexer.index_incremental

        expect(indexer).to have_received(:warn)
          .with(/refusing to prune 2 of 4.*WOODS_ALLOW_PURGE=1/m)
      end

      context 'with WOODS_ALLOW_PURGE=1' do
        before { ENV['WOODS_ALLOW_PURGE'] = '1' }
        after { ENV.delete('WOODS_ALLOW_PURGE') }

        it 'prunes the vanished units' do
          guarded_indexer.index_incremental

          expect(persisted_vector_ids).to contain_exactly('User', 'Invoice')
        end
      end
    end

    context 'when 30% or fewer of the persisted units vanished' do
      before { delete_unit_files('Order') } # 1 of 4 = 25%

      it 'prunes and rewrites the dump (the B-069 behaviour is preserved)' do
        stats = guarded_indexer.index_incremental

        expect(stats[:processed]).to eq(0)
        expect(persisted_vector_ids).to contain_exactly('User', 'PaymentService', 'Invoice')
      end
    end

    context 'on a full run' do
      it 'still dumps an empty store when the output dir holds no units' do
        # Full runs never reach the guard: there "nothing loaded" means the
        # store is genuinely empty and the dump must say so.
        delete_unit_files(*all_identifiers)

        fresh_indexer.index_all

        expect(persisted_vector_ids).to be_empty
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
