# frozen_string_literal: true

require 'spec_helper'
require 'woods/retrieval/scope'
require 'woods/retrieval/scoped_vector_store'
require 'woods/storage/vector_store'

RSpec.describe Woods::Retrieval::ScopedVectorStore do
  let(:metadata) { Woods::Storage::MetadataStore::InMemory.new }
  let(:vectors) { Woods::Storage::VectorStore::InMemory.new }

  def wrapper
    scope = Woods::Retrieval::Scope.new(metadata_store: metadata, packages: ['packs/billing'])
    described_class.new(store: vectors, scope: scope)
  end

  def add(name, vector, type: 'model', chunk: nil)
    key = Woods::StorageIdentity.key(name, type)
    metadata.store(key, { identifier: name, type: type, metadata: { package: 'packs/billing' } })
    id = chunk ? "#{key}#chunk_#{chunk}" : key
    vectors.store(id, vector)
    id
  end

  it 'searches all bounded partitions and finds the best hit beyond the first partition' do
    205.times { |i| add("Unit#{i}", [0.1, 1.0]) }
    best = add('Winner', [1.0, 0.0])
    allow(vectors).to receive(:search).and_call_original
    expect(wrapper.search([1.0, 0.0], limit: 1).map(&:id)).to eq([best])
    expect(vectors).to have_received(:search).exactly(3).times
    expect(vectors).to have_received(:search).with(anything, hash_including(ids: satisfy { |ids|
      ids.size <= 100
    })).exactly(3).times
  end

  it 'keeps the same result prefix across limits despite a backend with reversed score ties' do
    keys = Array.new(205) { |index| add("Unit#{index}", [1.0, 0.0]) }
    allow(vectors).to receive(:search) do |_query, limit:, ids:, **_options|
      ids.reverse.first(limit).map do |id|
        Woods::Storage::VectorStore::SearchResult.new(id: id, score: 1.0, metadata: {})
      end
    end
    short = wrapper.search([1.0, 0.0], limit: 3).map(&:id)
    long = wrapper.search([1.0, 0.0], limit: 205).first(3).map(&:id)
    expect(short).to eq(keys.sort.first(3))
    expect(short).to eq(long)
  end

  it 'retains eligible chunks and typed identities with no metadata payload' do
    chunk = add('Shared', [1.0, 0.0], chunk: 1)
    add('Shared', [0.1, 1.0], type: 'service')
    foreign = Woods::StorageIdentity.key('Shared', 'controller')
    vectors.store(foreign, [1.0, 0.0])
    expect(wrapper.search([1.0, 0.0], limit: 1).map(&:id)).to eq([chunk])
  end

  it 'refuses adapters without explicit native ID support' do
    add('Invoice', [1.0, 0.0])
    allow(vectors).to receive(:supports_id_filter?).and_return(false)
    expect { wrapper.search([1.0, 0.0]) }.to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /does not support/)
  end

  it 'refuses an adapter that violates the pre-limit ID filter contract' do
    add('Invoice', [1.0, 0.0])
    allow(vectors).to receive(:search).and_return([Woods::Storage::VectorStore::SearchResult.new(id: 'Outside',
                                                                                                 score: 1)])
    expect { wrapper.search([1.0, 0.0]) }.to raise_error(Woods::Retrieval::Scope::InvalidScopeError, /outside/)
  end
end
