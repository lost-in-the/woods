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
end
