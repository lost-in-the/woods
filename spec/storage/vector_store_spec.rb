# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/storage/vector_store'

RSpec.describe CodebaseIndex::Storage::VectorStore do
  describe CodebaseIndex::Storage::VectorStore::SearchResult do
    it 'stores id, score, and metadata' do
      result = described_class.new(id: 'doc1', score: 0.95, metadata: { type: 'model' })

      expect(result.id).to eq('doc1')
      expect(result.score).to eq(0.95)
      expect(result.metadata).to eq({ type: 'model' })
    end
  end

  describe 'Interface contract' do
    let(:dummy_class) do
      Class.new do
        include CodebaseIndex::Storage::VectorStore::Interface
      end
    end

    let(:dummy) { dummy_class.new }

    it 'raises NotImplementedError for #store' do
      expect { dummy.store('id', [1.0]) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #search' do
      expect { dummy.search([1.0]) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #delete' do
      expect { dummy.delete('id') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #delete_by_filter' do
      expect { dummy.delete_by_filter({}) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for #count' do
      expect { dummy.count }.to raise_error(NotImplementedError)
    end
  end

  describe CodebaseIndex::Storage::VectorStore::InMemory do
    let(:store) { described_class.new }

    describe '#store and #count' do
      it 'stores vectors and tracks count' do
        expect(store.count).to eq(0)

        store.store('doc1', [1.0, 0.0, 0.0])
        expect(store.count).to eq(1)

        store.store('doc2', [0.0, 1.0, 0.0])
        expect(store.count).to eq(2)
      end

      it 'overwrites duplicate IDs' do
        store.store('doc1', [1.0, 0.0], { version: 1 })
        store.store('doc1', [0.0, 1.0], { version: 2 })

        expect(store.count).to eq(1)

        results = store.search([0.0, 1.0], limit: 1)
        expect(results.first.metadata).to eq({ version: 2 })
      end
    end

    describe '#search' do
      before do
        store.store('model_user', [1.0, 0.0, 0.0], { type: 'model' })
        store.store('model_order', [0.9, 0.1, 0.0], { type: 'model' })
        store.store('service_auth', [0.0, 1.0, 0.0], { type: 'service' })
        store.store('controller_users', [0.0, 0.0, 1.0], { type: 'controller' })
      end

      it 'returns results sorted by descending similarity' do
        results = store.search([1.0, 0.0, 0.0])

        expect(results.first.id).to eq('model_user')
        expect(results.first.score).to be_within(0.001).of(1.0)
        expect(results[1].id).to eq('model_order')
      end

      it 'respects the limit parameter' do
        results = store.search([1.0, 0.0, 0.0], limit: 2)

        expect(results.size).to eq(2)
      end

      it 'filters by metadata' do
        results = store.search([1.0, 0.0, 0.0], filters: { type: 'model' })

        expect(results.map(&:id)).to contain_exactly('model_user', 'model_order')
      end

      it 'returns empty array when no matches pass filters' do
        results = store.search([1.0, 0.0, 0.0], filters: { type: 'nonexistent' })

        expect(results).to be_empty
      end

      it 'returns empty array for empty store' do
        empty_store = described_class.new

        results = empty_store.search([1.0, 0.0])

        expect(results).to be_empty
      end

      it 'handles zero-magnitude vectors gracefully' do
        store.store('zero', [0.0, 0.0, 0.0])

        results = store.search([1.0, 0.0, 0.0])
        zero_result = results.find { |r| r.id == 'zero' }

        expect(zero_result.score).to eq(0.0)
      end
    end

    describe '#delete' do
      it 'removes a vector by ID' do
        store.store('doc1', [1.0, 0.0])
        store.store('doc2', [0.0, 1.0])

        store.delete('doc1')

        expect(store.count).to eq(1)
        results = store.search([1.0, 0.0])
        expect(results.map(&:id)).to eq(['doc2'])
      end

      it 'does nothing for nonexistent IDs' do
        store.store('doc1', [1.0])

        store.delete('nonexistent')

        expect(store.count).to eq(1)
      end
    end

    describe '#delete_by_filter' do
      it 'removes vectors matching metadata filters' do
        store.store('m1', [1.0], { type: 'model', app: 'main' })
        store.store('m2', [0.5], { type: 'model', app: 'main' })
        store.store('s1', [0.0], { type: 'service', app: 'main' })

        store.delete_by_filter({ type: 'model' })

        expect(store.count).to eq(1)
        results = store.search([1.0])
        expect(results.first.id).to eq('s1')
      end

      it 'does nothing when no vectors match' do
        store.store('doc1', [1.0], { type: 'model' })

        store.delete_by_filter({ type: 'nonexistent' })

        expect(store.count).to eq(1)
      end
    end
  end
end
