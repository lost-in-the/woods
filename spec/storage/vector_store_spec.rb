# frozen_string_literal: true

require 'spec_helper'
require 'woods/storage/vector_store'

RSpec.describe Woods::Storage::VectorStore do
  describe Woods::Storage::VectorStore::SearchResult do
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
        include Woods::Storage::VectorStore::Interface
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

  describe Woods::Storage::VectorStore::InMemory do
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

      it 'treats Array filter values as membership (#108)' do
        results = store.search([1.0, 0.0, 0.0], filters: { type: %w[model service] })
        expect(results.map(&:id)).to contain_exactly('model_user', 'model_order', 'service_auth')
      end

      it 'an empty Array filter matches nothing' do
        results = store.search([1.0, 0.0, 0.0], filters: { type: [] })
        expect(results).to be_empty
      end

      it 'matches string-keyed filters against symbol-keyed metadata (#150)' do
        results = store.search([1.0, 0.0, 0.0], filters: { 'type' => 'model' })

        expect(results.map(&:id)).to contain_exactly('model_user', 'model_order')
      end

      it 'matches symbol-keyed filters against string-keyed metadata (#150)' do
        store.store('legacy_hydrated', [0.9, 0.1, 0.0], { 'type' => 'model' })

        results = store.search([1.0, 0.0, 0.0], filters: { type: 'model' })

        expect(results.map(&:id)).to include('legacy_hydrated')
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

      it 'raises ArgumentError when query vector dimensions do not match stored vector dimensions' do
        store.store('doc1', [1.0, 0.0, 0.0], { type: 'model' })

        expect { store.search([1.0, 0.0]) }.to raise_error(
          ArgumentError, /Vector dimension mismatch \(2 vs 3\)/
        )
      end

      it 'matches the reference zip/sum cosine computation bit-for-bit' do
        # The strided while-loop kernel must produce identical results to
        # the naive Enumerable implementation it replaced. Any drift here
        # means we silently shifted search rankings.
        rng = Random.new(12_345)
        ref = lambda { |a, b|
          dot = a.zip(b).sum { |x, y| x * y }
          mag_a = Math.sqrt(a.sum { |x| x**2 })
          mag_b = Math.sqrt(b.sum { |x| x**2 })
          mag_a.zero? || mag_b.zero? ? 0.0 : dot / (mag_a * mag_b)
        }

        fresh = described_class.new
        50.times do |i|
          fresh.store("v_#{i}", Array.new(128) { rng.rand(-1.0..1.0) })
        end
        query = Array.new(128) { rng.rand(-1.0..1.0) }
        results = fresh.search(query, limit: 50)

        stored_by_id = {}
        fresh.each_entry { |id, vec, _meta| stored_by_id[id] = vec }

        results.each do |r|
          expect(r.score).to be_within(1e-12).of(ref.call(query, stored_by_id[r.id]))
        end
      end

      it 'rejects a query whose dimension disagrees with stored vectors' do
        fresh = described_class.new
        fresh.store('doc1', [1.0, 0.0], { type: 'model' })

        expect { fresh.search([1.0, 0.0, 0.0]) }
          .to raise_error(ArgumentError, /Vector dimension mismatch/)
      end

      it 'rejects a stored vector whose dimension disagrees with the first one' do
        fresh = described_class.new
        fresh.store('a', [1.0, 0.0, 0.0])

        expect { fresh.store('b', [1.0, 0.0]) }
          .to raise_error(ArgumentError, /Vector dimension mismatch/)
      end

      it 'allocates no per-pair objects during search' do
        # The whole point of the while-loop kernel. The baseline
        # zip/sum produced ~770 allocations per cosine call, ~9.8M for
        # a 12 k-entry search. The while-loop must be well under
        # per-entry allocation — we allow a small constant for the
        # SearchResult objects and sort scaffolding, but the inner
        # loop itself must be clean.
        fresh = described_class.new
        1000.times { |i| fresh.store("v_#{i}", Array.new(256) { rand(-1.0..1.0) }) }
        query = Array.new(256) { rand(-1.0..1.0) }

        # Warm caches and stabilise inline constants.
        3.times { fresh.search(query, limit: 10) }
        GC.start

        before = GC.stat(:total_allocated_objects)
        fresh.search(query, limit: 10)
        allocations = GC.stat(:total_allocated_objects) - before

        # Realistic bound: ~1 SearchResult per candidate + sort overhead
        # + a handful of bookkeeping objects. The OLD path produced ~770k
        # allocations for 1000 candidates; the new path must be under
        # ~3× the candidate count. 5× gives headroom for Ruby version drift.
        expect(allocations).to be < 5000
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

    # ── Persistence seams ───────────────────────────────────────────
    # #each_entry and #bulk_load are the contract the Snapshotter
    # (coming in a later PR) uses to hydrate a store from disk and
    # iterate it for dumping. Behavior must be:
    #   - each_entry yields (id, vector, metadata) for every live entry
    #   - tombstoned (deleted) entries are skipped
    #   - bulk_load is the round-trip dual — dump then load recreates
    #     the same observable state
    describe '#each_entry' do
      it 'yields every live entry with id, vector, and metadata' do
        store.store('a', [1.0, 0.0], { type: 'model' })
        store.store('b', [0.0, 1.0], { type: 'service' })

        yielded = []
        store.each_entry { |id, vec, meta| yielded << [id, vec, meta] }

        expect(yielded).to contain_exactly(
          ['a', [1.0, 0.0], { type: 'model' }],
          ['b', [0.0, 1.0], { type: 'service' }]
        )
      end

      it 'skips deleted entries (tombstones)' do
        store.store('a', [1.0, 0.0])
        store.store('b', [0.0, 1.0])
        store.delete('a')

        ids = []
        store.each_entry { |id, _, _| ids << id }

        expect(ids).to eq(['b'])
      end

      it 'returns an Enumerator when called without a block' do
        store.store('a', [1.0, 0.0])
        expect(store.each_entry).to be_a(Enumerator)
      end

      it 'yields frozen id strings so downstream hashes are safe' do
        store.store('doc1', [1.0, 0.0])

        store.each_entry { |id, _, _| expect(id).to be_frozen }
      end
    end

    describe '#bulk_load round-trip' do
      it 'recreates the same observable state when fed each_entry output' do
        store.store('a', [1.0, 0.0, 0.0], { type: 'model' })
        store.store('b', [0.0, 1.0, 0.0], { type: 'service' })
        store.store('c', [0.0, 0.0, 1.0], { type: 'controller' })

        entries = store.each_entry.map { |id, vec, meta| { id: id, vector: vec, metadata: meta } }
        rehydrated = described_class.new
        rehydrated.bulk_load(entries)

        query = [1.0, 0.0, 0.0]
        original_results = store.search(query).map { |r| [r.id, r.score.round(9), r.metadata] }
        reloaded_results = rehydrated.search(query).map { |r| [r.id, r.score.round(9), r.metadata] }

        expect(reloaded_results).to eq(original_results)
        expect(rehydrated.count).to eq(store.count)
      end

      it 'preserves insertion order so dump/load is deterministic' do
        store.store('a', [1.0])
        store.store('b', [1.0])
        store.store('c', [1.0])

        loaded = described_class.new
        loaded.bulk_load(store.each_entry.map { |id, v, m| { id: id, vector: v, metadata: m } })

        expect(loaded.each_entry.map { |id, _, _| id }).to eq(%w[a b c])
      end
    end
  end
end
