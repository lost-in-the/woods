# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/vector_store'
require 'codebase_index/storage/pgvector'

RSpec.describe CodebaseIndex::Storage::VectorStore::Pgvector do
  let(:connection) { instance_double('ActiveRecord::ConnectionAdapters::AbstractAdapter') }
  let(:store) { described_class.new(connection: connection, dimensions: 3) }

  describe '#initialize' do
    it 'stores the connection and dimensions' do
      expect(store).to be_a(described_class)
    end
  end

  describe '#ensure_schema!' do
    it 'creates the extension, table, and index' do
      allow(connection).to receive(:execute)

      store.ensure_schema!

      expect(connection).to have_received(:execute).with(/CREATE EXTENSION IF NOT EXISTS vector/)
      expect(connection).to have_received(:execute).with(/CREATE TABLE IF NOT EXISTS codebase_index_vectors/)
      expect(connection).to have_received(:execute).with(/CREATE INDEX IF NOT EXISTS/)
    end

    it 'creates a vector column with the correct dimensions' do
      allow(connection).to receive(:execute)

      store.ensure_schema!

      expect(connection).to have_received(:execute).with(/vector\(3\)/)
    end
  end

  describe '#store' do
    it 'upserts a vector with metadata' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.store('doc1', [0.1, 0.2, 0.3], { type: 'model' })

      expect(connection).to have_received(:execute).with(/INSERT INTO codebase_index_vectors/)
      expect(connection).to have_received(:execute).with(/ON CONFLICT \(id\) DO UPDATE/)
    end

    it 'quotes values to prevent SQL injection' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.store('doc1', [0.1, 0.2, 0.3])

      expect(connection).to have_received(:quote).at_least(:once)
    end
  end

  describe '#search' do
    let(:result_row) do
      { 'id' => 'doc1', 'distance' => 0.1, 'metadata' => '{"type":"model"}' }
    end

    before do
      allow(connection).to receive(:execute).and_return([result_row])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }
    end

    it 'returns an array of SearchResult objects' do
      results = store.search([0.1, 0.2, 0.3], limit: 5)

      expect(results).to all(be_a(CodebaseIndex::Storage::VectorStore::SearchResult))
    end

    it 'converts distance to similarity score' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.score).to be_within(0.001).of(0.9)
    end

    it 'parses metadata JSON' do
      results = store.search([0.1, 0.2, 0.3])

      expect(results.first.metadata).to eq({ 'type' => 'model' })
    end

    it 'respects the limit parameter' do
      store.search([0.1, 0.2, 0.3], limit: 5)

      expect(connection).to have_received(:execute).with(/LIMIT 5/)
    end

    it 'applies metadata filters' do
      store.search([0.1, 0.2, 0.3], filters: { type: 'model' })

      expect(connection).to have_received(:execute).with(/metadata->>'type' = 'model'/)
    end

    it 'returns empty array when no results' do
      allow(connection).to receive(:execute).and_return([])

      results = store.search([0.1, 0.2, 0.3])

      expect(results).to be_empty
    end
  end

  describe '#delete' do
    it 'deletes by ID' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete('doc1')

      expect(connection).to have_received(:execute).with(/DELETE FROM codebase_index_vectors WHERE id = /)
    end
  end

  describe '#delete_by_filter' do
    it 'deletes by metadata filter' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete_by_filter({ type: 'model' })

      expect(connection).to have_received(:execute)
        .with(/DELETE FROM codebase_index_vectors WHERE metadata->>'type' = 'model'/)
    end

    it 'handles multiple filters' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      store.delete_by_filter({ type: 'model', app: 'main' })

      expect(connection).to have_received(:execute).with(/metadata->>'type' = 'model'/)
      expect(connection).to have_received(:execute).with(/metadata->>'app' = 'main'/)
    end
  end

  describe '#count' do
    it 'returns the number of stored vectors' do
      allow(connection).to receive(:execute).and_return([{ 'count' => 42 }])

      expect(store.count).to eq(42)
    end
  end

  describe 'Interface compliance' do
    it 'includes VectorStore::Interface' do
      expect(described_class.ancestors).to include(CodebaseIndex::Storage::VectorStore::Interface)
    end
  end

  describe '#build_where security' do
    it 'rejects malicious filter keys' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { "'; DROP TABLE users; --" => 'x' }) }
        .to raise_error(ArgumentError, /Invalid filter key/)
    end

    it 'accepts valid filter keys' do
      allow(connection).to receive(:execute).and_return([])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { type: 'model' }) }.not_to raise_error
    end

    it 'accepts filter keys with underscores and numbers' do
      allow(connection).to receive(:execute).and_return([])
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.search([0.1, 0.2, 0.3], filters: { unit_type: 'model' }) }.not_to raise_error
    end
  end

  describe 'vector validation' do
    it 'rejects non-numeric vector elements on store' do
      allow(connection).to receive(:execute)
      allow(connection).to receive(:quote) { |v| "'#{v}'" }

      expect { store.store('doc1', [0.1, 'malicious', 0.3]) }
        .to raise_error(ArgumentError, /not numeric/)
    end

    it 'rejects non-numeric vector elements on search' do
      expect { store.search([0.1, nil, 0.3]) }
        .to raise_error(ArgumentError, /not numeric/)
    end
  end
end
