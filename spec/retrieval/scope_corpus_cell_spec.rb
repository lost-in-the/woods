# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/scope_corpus_cell'
require 'woods/retrieval/scope_corpus'
require 'woods/storage/metadata_store'

# F6 step 2. One pipeline keeps one scope corpus: built on the first scoped
# request, reused while its source is unchanged, dropped with the pipeline.
RSpec.describe Woods::Retrieval::ScopeCorpusCell do
  let(:store) { Woods::Storage::MetadataStore::InMemory.new }

  before { store.store('Invoice', { type: 'model', identifier: 'Invoice', metadata: { package: 'packs/billing' } }) }

  describe '.pinned' do
    it 'builds once and answers the same corpus for the life of the cell' do
      builds = 0
      cell = described_class.pinned do
        builds += 1
        Woods::Retrieval::ScopeCorpus.from_store(store)
      end
      first = cell.current
      store.store('Order', { type: 'model', identifier: 'Order' })
      expect(cell.current).to equal(first)
      expect(builds).to eq(1)
      expect(first.keys).to eq(['Invoice'])
    end
  end

  describe '.versioned' do
    it 'reuses the corpus while the store version stands and rebuilds after a content change' do
      builds = 0
      cell = described_class.versioned(store) do
        builds += 1
        Woods::Retrieval::ScopeCorpus.from_store(store)
      end
      first = cell.current
      store.store('Invoice', { type: 'model', identifier: 'Invoice', metadata: { package: 'packs/billing' } })
      expect(cell.current).to equal(first)
      expect(builds).to eq(1)

      store.store('Order', { type: 'model', identifier: 'Order' })
      rebuilt = cell.current
      expect(rebuilt).not_to equal(first)
      expect(rebuilt.keys).to eq(%w[Invoice Order])
      expect(cell.current).to equal(rebuilt)
      expect(builds).to eq(2)
    end

    it 'keeps nothing for a store that tracks no changes' do
      versionless = Woods::Storage::MetadataStore::SQLite.new(database: ':memory:')
      builds = 0
      cell = described_class.versioned(versionless) { builds += 1 }
      expect([cell.current, cell.current]).to eq([nil, nil])
      expect(builds).to eq(0)
    end

    it 'caches nothing from a build that raises' do
      attempts = 0
      cell = described_class.versioned(store) do
        attempts += 1
        raise Woods::Retrieval::Scope::InvalidScopeError, 'missing metadata' if attempts == 1

        Woods::Retrieval::ScopeCorpus.from_store(store)
      end
      expect { cell.current }.to raise_error(Woods::Retrieval::Scope::InvalidScopeError)
      expect(cell.current).to be_a(Woods::Retrieval::ScopeCorpus)
      expect(attempts).to eq(2)
    end
  end
end
