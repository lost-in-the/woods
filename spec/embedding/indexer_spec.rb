# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'codebase_index'
require 'codebase_index/embedding/indexer'
require 'codebase_index/embedding/text_preparer'
require 'codebase_index/embedding/provider'

RSpec.describe CodebaseIndex::Embedding::Indexer do
  let(:output_dir) { '/tmp/claude/indexer_test' }

  let(:provider) do
    instance_double('Provider', embed: [0.1, 0.2], embed_batch: [[0.1, 0.2], [0.3, 0.4]])
  end

  let(:text_preparer) { CodebaseIndex::Embedding::TextPreparer.new }

  let(:vector_store) do
    instance_double('VectorStore', store: nil, delete: nil, count: 0)
  end

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
    # Clean up any previous test files
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

    it 'calls embed_batch on the provider' do
      indexer.index_all
      expect(provider).to have_received(:embed_batch)
    end

    it 'stores vectors in the vector store' do
      indexer.index_all
      expect(vector_store).to have_received(:store).with(
        'User',
        [0.1, 0.2],
        hash_including(type: 'model', identifier: 'User')
      )
    end

    it 'writes a checkpoint file' do
      indexer.index_all
      checkpoint = JSON.parse(File.read(File.join(output_dir, 'checkpoint.json')))
      expect(checkpoint['User']).to eq('abc123')
    end

    context 'with multiple units' do
      before do
        File.write(File.join(output_dir, 'payment_service.json'), JSON.generate(second_unit_data))
      end

      it 'processes all units' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(2)
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
        allow(provider).to receive(:embed_batch).and_return([[0.1, 0.2], [0.3, 0.4]])
      end

      it 'creates one embedding per chunk' do
        stats = indexer.index_all
        expect(stats[:processed]).to eq(2)
      end

      it 'stores each chunk with a chunk suffix ID' do
        indexer.index_all
        expect(vector_store).to have_received(:store).with(
          'User#chunk_0', anything, anything
        )
        expect(vector_store).to have_received(:store).with(
          'User#chunk_1', anything, anything
        )
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

      it 'skips unchanged units' do
        stats = indexer.index_incremental
        expect(stats[:processed]).to eq(0)
        expect(stats[:skipped]).to eq(1)
      end

      it 'does not call the provider' do
        indexer.index_incremental
        expect(provider).not_to have_received(:embed_batch)
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
    before do
      File.write(File.join(output_dir, 'user.json'), JSON.generate(unit_data))
      allow(provider).to receive(:embed_batch).and_raise(StandardError, 'connection refused')
    end

    it 'raises CodebaseIndex::Error on provider failure' do
      expect { indexer.index_all }.to raise_error(
        CodebaseIndex::Error, /Embedding failed: connection refused/
      )
    end
  end

  describe 'empty output directory' do
    it 'returns zero stats when no files exist' do
      stats = indexer.index_all
      expect(stats).to eq({ processed: 0, skipped: 0, errors: 0 })
    end
  end
end
