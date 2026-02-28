# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/cache/cache_store'
require 'codebase_index/cache/cache_middleware'

RSpec.shared_examples 'a CacheStore' do
  describe '#write and #read' do
    it 'stores and retrieves a string value' do
      store.write('key:1', 'hello')
      expect(store.read('key:1')).to eq('hello')
    end

    it 'stores and retrieves an array value' do
      store.write('key:2', [0.1, 0.2, 0.3])
      expect(store.read('key:2')).to eq([0.1, 0.2, 0.3])
    end

    it 'stores and retrieves a hash value' do
      store.write('key:3', { 'name' => 'User', 'type' => 'model' })
      expect(store.read('key:3')).to eq({ 'name' => 'User', 'type' => 'model' })
    end

    it 'returns nil for a missing key' do
      expect(store.read('nonexistent')).to be_nil
    end

    it 'overwrites existing values' do
      store.write('key:4', 'first')
      store.write('key:4', 'second')
      expect(store.read('key:4')).to eq('second')
    end
  end

  describe '#exist?' do
    it 'returns true for an existing key' do
      store.write('key:exists', 'value')
      expect(store.exist?('key:exists')).to be true
    end

    it 'returns false for a missing key' do
      expect(store.exist?('key:missing')).to be false
    end
  end

  describe '#delete' do
    it 'removes a key' do
      store.write('key:del', 'gone')
      store.delete('key:del')
      expect(store.read('key:del')).to be_nil
    end

    it 'does not raise when deleting a nonexistent key' do
      expect { store.delete('key:nope') }.not_to raise_error
    end
  end

  describe '#fetch' do
    it 'returns cached value on hit' do
      store.write('key:fetch', 'cached')
      result = store.fetch('key:fetch') { 'computed' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('cached')
    end

    it 'executes block and caches on miss' do
      result = store.fetch('key:fetch_miss') { 'computed' } # rubocop:disable Style/RedundantFetchBlock
      expect(result).to eq('computed')
      expect(store.read('key:fetch_miss')).to eq('computed')
    end

    it 'does not execute block on hit' do
      store.write('key:fetch_noop', 'cached')
      called = false
      store.fetch('key:fetch_noop') do
        called = true
        'computed'
      end
      expect(called).to be false
    end
  end
end

# ── InMemory ───────────────────────────────────────────────────────────

RSpec.describe CodebaseIndex::Cache::InMemory do
  subject(:store) { described_class.new(max_entries: 5) }

  include_examples 'a CacheStore'

  describe 'TTL expiry' do
    it 'returns nil for expired entries' do
      store.write('key:ttl', 'ephemeral', ttl: 0)
      # TTL of 0 means expires immediately — sleep a tiny amount for Time.now to advance
      sleep 0.01
      expect(store.read('key:ttl')).to be_nil
    end

    it 'returns value for non-expired entries' do
      store.write('key:ttl2', 'persistent', ttl: 60)
      expect(store.read('key:ttl2')).to eq('persistent')
    end

    it 'reports expired entries as not existing' do
      store.write('key:ttl3', 'temp', ttl: 0)
      sleep 0.01
      expect(store.exist?('key:ttl3')).to be false
    end
  end

  describe 'LRU eviction' do
    it 'evicts the oldest entry when at capacity' do
      5.times { |i| store.write("key:#{i}", "val#{i}") }

      # Add one more — should evict key:0
      store.write('key:5', 'val5')

      expect(store.read('key:0')).to be_nil
      expect(store.read('key:5')).to eq('val5')
    end

    it 'touching a key prevents its eviction' do
      5.times { |i| store.write("key:#{i}", "val#{i}") }

      # Read key:0 to move it to most-recently-used
      store.read('key:0')

      # Add one more — should evict key:1 (now oldest)
      store.write('key:5', 'val5')

      expect(store.read('key:0')).to eq('val0')
      expect(store.read('key:1')).to be_nil
    end
  end

  describe '#clear' do
    it 'clears all entries when no namespace given' do
      store.write('codebase_index:cache:embeddings:a', 'v1')
      store.write('codebase_index:cache:context:b', 'v2')
      store.clear
      expect(store.size).to eq(0)
    end

    it 'clears only matching namespace' do
      store.write('codebase_index:cache:embeddings:a', 'v1')
      store.write('codebase_index:cache:context:b', 'v2')
      store.clear(namespace: :embeddings)
      expect(store.read('codebase_index:cache:embeddings:a')).to be_nil
      expect(store.read('codebase_index:cache:context:b')).to eq('v2')
    end
  end

  describe '#size' do
    it 'returns 0 for empty store' do
      expect(store.size).to eq(0)
    end

    it 'tracks entry count' do
      store.write('a', 1)
      store.write('b', 2)
      expect(store.size).to eq(2)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent writes without errors' do
      large_store = described_class.new(max_entries: 1000)
      threads = 4.times.map do |t|
        Thread.new do
          50.times do |i|
            large_store.write("thread:#{t}:#{i}", "val#{i}")
          end
        end
      end
      threads.each(&:join)

      # All threads completed without raising
      expect(large_store.size).to be <= 1000
      expect(large_store.size).to be > 0
    end
  end
end

# ── Cache.cache_key ────────────────────────────────────────────────────

RSpec.describe CodebaseIndex::Cache do
  describe '.cache_key' do
    it 'builds a namespaced key' do
      key = described_class.cache_key(:embeddings, 'abc123')
      expect(key).to eq('codebase_index:cache:embeddings:abc123')
    end

    it 'hashes long keys with SHA256' do
      long_part = 'x' * 100
      key = described_class.cache_key(:context, long_part)
      expect(key).to start_with('codebase_index:cache:context:')
      # The suffix should be a SHA256 hex digest (64 chars)
      suffix = key.split(':').last
      expect(suffix.length).to eq(64)
    end

    it 'concatenates multiple parts' do
      key = described_class.cache_key(:context, 'query', '8000')
      expect(key).to eq('codebase_index:cache:context:query:8000')
    end
  end
end

# ── CachedEmbeddingProvider ────────────────────────────────────────────

RSpec.describe CodebaseIndex::Cache::CachedEmbeddingProvider do
  let(:cache_store) { CodebaseIndex::Cache::InMemory.new }
  let(:provider) do
    instance_double('EmbeddingProvider',
                    dimensions: 768,
                    model_name: 'test-model')
  end
  let(:cached_provider) do
    described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)
  end

  describe '#embed' do
    it 'calls provider on first request' do
      allow(provider).to receive(:embed).with('hello').and_return([0.1, 0.2])

      result = cached_provider.embed('hello')

      expect(result).to eq([0.1, 0.2])
      expect(provider).to have_received(:embed).once
    end

    it 'returns cached vector on second request' do
      allow(provider).to receive(:embed).with('hello').and_return([0.1, 0.2])

      cached_provider.embed('hello')
      result = cached_provider.embed('hello')

      expect(result).to eq([0.1, 0.2])
      expect(provider).to have_received(:embed).once
    end

    it 'caches different texts independently' do
      allow(provider).to receive(:embed).with('hello').and_return([0.1])
      allow(provider).to receive(:embed).with('world').and_return([0.2])

      cached_provider.embed('hello')
      cached_provider.embed('world')

      expect(provider).to have_received(:embed).twice
    end
  end

  describe '#embed_batch' do
    it 'calls provider for all texts on first batch' do
      allow(provider).to receive(:embed_batch)
        .with(%w[a b c])
        .and_return([[0.1], [0.2], [0.3]])

      result = cached_provider.embed_batch(%w[a b c])

      expect(result).to eq([[0.1], [0.2], [0.3]])
      expect(provider).to have_received(:embed_batch).once
    end

    it 'only sends uncached texts to provider on subsequent calls' do
      allow(provider).to receive(:embed).with('a').and_return([0.1])
      allow(provider).to receive(:embed_batch).with(['c']).and_return([[0.3]])

      # Pre-cache 'a'
      cached_provider.embed('a')

      # Batch with 'a' (cached) and 'c' (uncached)
      result = cached_provider.embed_batch(%w[a c])

      expect(result).to eq([[0.1], [0.3]])
      expect(provider).not_to have_received(:embed_batch).with(%w[a c])
      expect(provider).to have_received(:embed_batch).with(['c'])
    end

    it 'skips provider call when all texts are cached' do
      allow(provider).to receive(:embed_batch)
        .with(%w[x y])
        .and_return([[0.1], [0.2]])

      cached_provider.embed_batch(%w[x y])

      allow(provider).to receive(:embed_batch)
      result = cached_provider.embed_batch(%w[x y])

      expect(result).to eq([[0.1], [0.2]])
      # Only the first call should have gone through
      expect(provider).to have_received(:embed_batch).once
    end
  end

  describe '#dimensions' do
    it 'delegates to the underlying provider' do
      expect(cached_provider.dimensions).to eq(768)
    end
  end

  describe '#model_name' do
    it 'delegates to the underlying provider' do
      expect(cached_provider.model_name).to eq('test-model')
    end
  end
end

# ── CachedRetriever ────────────────────────────────────────────────────

RSpec.describe CodebaseIndex::Cache::CachedRetriever do
  let(:cache_store) { CodebaseIndex::Cache::InMemory.new }
  let(:retrieval_result) do
    CodebaseIndex::Retriever::RetrievalResult.new(
      context: '## User (model)\nclass User < ApplicationRecord\nend',
      sources: %w[User],
      classification: nil,
      strategy: :vector,
      tokens_used: 42,
      budget: 8000,
      trace: nil
    )
  end
  let(:retriever) { instance_double(CodebaseIndex::Retriever) }
  let(:cached_retriever) do
    described_class.new(retriever: retriever, cache_store: cache_store, context_ttl: 900)
  end

  describe '#retrieve' do
    it 'delegates to the real retriever on cache miss' do
      allow(retriever).to receive(:retrieve)
        .with('How does User work?', budget: 8000)
        .and_return(retrieval_result)

      result = cached_retriever.retrieve('How does User work?')

      expect(result.context).to eq(retrieval_result.context)
      expect(retriever).to have_received(:retrieve).once
    end

    it 'returns cached result on cache hit' do
      allow(retriever).to receive(:retrieve)
        .with('How does User work?', budget: 8000)
        .and_return(retrieval_result)

      cached_retriever.retrieve('How does User work?')
      result = cached_retriever.retrieve('How does User work?')

      expect(result.context).to eq(retrieval_result.context)
      expect(result.strategy).to eq(:vector)
      expect(result.tokens_used).to eq(42)
      expect(retriever).to have_received(:retrieve).once
    end

    it 'caches different queries independently' do
      result_a = CodebaseIndex::Retriever::RetrievalResult.new(
        context: 'A', sources: [], classification: nil,
        strategy: :vector, tokens_used: 10, budget: 8000, trace: nil
      )
      result_b = CodebaseIndex::Retriever::RetrievalResult.new(
        context: 'B', sources: [], classification: nil,
        strategy: :keyword, tokens_used: 20, budget: 8000, trace: nil
      )

      allow(retriever).to receive(:retrieve).with('query A', budget: 8000).and_return(result_a)
      allow(retriever).to receive(:retrieve).with('query B', budget: 8000).and_return(result_b)

      cached_retriever.retrieve('query A')
      cached_retriever.retrieve('query B')

      expect(retriever).to have_received(:retrieve).twice
    end

    it 'treats different budgets as different cache keys' do
      result_small = CodebaseIndex::Retriever::RetrievalResult.new(
        context: 'small', sources: [], classification: nil,
        strategy: :vector, tokens_used: 5, budget: 2000, trace: nil
      )
      result_large = CodebaseIndex::Retriever::RetrievalResult.new(
        context: 'large', sources: [], classification: nil,
        strategy: :vector, tokens_used: 50, budget: 16_000, trace: nil
      )

      allow(retriever).to receive(:retrieve).with('query', budget: 2000).and_return(result_small)
      allow(retriever).to receive(:retrieve).with('query', budget: 16_000).and_return(result_large)

      r1 = cached_retriever.retrieve('query', budget: 2000)
      r2 = cached_retriever.retrieve('query', budget: 16_000)

      expect(r1.context).to eq('small')
      expect(r2.context).to eq('large')
    end
  end
end

# ── DEFAULT_TTLS ───────────────────────────────────────────────────────

RSpec.describe 'CodebaseIndex::Cache::DEFAULT_TTLS' do
  it 'defines all expected domains' do
    expect(CodebaseIndex::Cache::DEFAULT_TTLS.keys).to contain_exactly(
      :embeddings, :metadata, :structural, :search, :context
    )
  end

  it 'has positive integer values for all domains' do
    CodebaseIndex::Cache::DEFAULT_TTLS.each_value do |ttl|
      expect(ttl).to be_a(Integer)
      expect(ttl).to be > 0
    end
  end

  it 'is frozen' do
    expect(CodebaseIndex::Cache::DEFAULT_TTLS).to be_frozen
  end
end
