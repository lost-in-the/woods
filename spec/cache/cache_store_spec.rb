# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/cache/cache_store'
require 'woods/cache/cache_middleware'
require 'woods/cache/redis_cache_store'
require 'woods/cache/solid_cache_store'

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

RSpec.describe Woods::Cache::InMemory do
  subject(:store) { described_class.new(max_entries: 5) }

  include_examples 'a CacheStore'

  describe 'TTL expiry' do
    it 'returns nil for expired entries' do
      store.write('key:ttl', 'ephemeral', ttl: 0)
      # TTL of 0 means expires immediately — sleep a tiny amount for Time.now to advance
      sleep 0.05
      expect(store.read('key:ttl')).to be_nil
    end

    it 'returns value for non-expired entries' do
      store.write('key:ttl2', 'persistent', ttl: 60)
      expect(store.read('key:ttl2')).to eq('persistent')
    end

    it 'reports expired entries as not existing' do
      store.write('key:ttl3', 'temp', ttl: 0)
      sleep 0.05
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
      store.write('woods:cache:embeddings:a', 'v1')
      store.write('woods:cache:context:b', 'v2')
      store.clear
      expect(store.size).to eq(0)
    end

    it 'clears only matching namespace' do
      store.write('woods:cache:embeddings:a', 'v1')
      store.write('woods:cache:context:b', 'v2')
      store.clear(namespace: :embeddings)
      expect(store.read('woods:cache:embeddings:a')).to be_nil
      expect(store.read('woods:cache:context:b')).to eq('v2')
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

RSpec.describe Woods::Cache do
  describe '.cache_key' do
    it 'builds a namespaced key' do
      key = described_class.cache_key(:embeddings, 'abc123')
      expect(key).to eq('woods:cache:embeddings:abc123')
    end

    it 'hashes long keys with SHA256' do
      long_part = 'x' * 100
      key = described_class.cache_key(:context, long_part)
      expect(key).to start_with('woods:cache:context:')
      # The suffix should be a SHA256 hex digest (64 chars)
      suffix = key.split(':').last
      expect(suffix.length).to eq(64)
    end

    it 'concatenates multiple parts' do
      key = described_class.cache_key(:context, 'query', '8000')
      expect(key).to eq('woods:cache:context:query:8000')
    end
  end
end

# ── CachedEmbeddingProvider ────────────────────────────────────────────

RSpec.describe Woods::Cache::CachedEmbeddingProvider do
  let(:cache_store) { Woods::Cache::InMemory.new }
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

  # Regression — round-5 audit X-1 / issue #88. Without per-text single-flight,
  # N threads missing on the same text all fan out to the provider, burning API
  # quota and tripping rate limits. These specs stage a stampede deterministically
  # with a Queue barrier and assert the provider is called exactly once per text.
  describe '#embed_batch single-flight under concurrent misses' do
    let(:provider) do
      instance_double('EmbeddingProvider',
                      dimensions: 768,
                      model_name: 'test-model')
    end

    it 'deduplicates provider calls when N threads miss on the same texts' do
      call_mutex = Mutex.new
      call_count = 0
      started = Queue.new
      release = Queue.new

      allow(provider).to receive(:embed_batch) do |texts|
        call_mutex.synchronize { call_count += 1 }
        started << :go
        release.pop # hold the provider call open until released
        texts.map { |t| [t.bytesize] }
      end

      thread_count = 5
      threads = Array.new(thread_count) do
        Thread.new { cached_provider.embed_batch(%w[shared-a shared-b]) }
      end

      started.pop      # wait for at least one provider call to begin
      sleep 0.1        # give any stampeders time to also enter embed_batch
      # Enough release tokens to unblock any path (broken or fixed). Excess tokens
      # are harmless — the queue is drained when the spec ends.
      thread_count.times { release << :go }

      results = threads.map(&:value)

      expect(call_count).to eq(1)
      expect(results).to all(eq([[8], [8]])) # 'shared-a'.bytesize == 8
    end

    it 'parallelizes disjoint batches instead of serializing on a global lock' do
      mutex = Mutex.new
      in_flight = 0
      max_in_flight = 0

      allow(provider).to receive(:embed_batch) do |texts|
        mutex.synchronize do
          in_flight += 1
          max_in_flight = [max_in_flight, in_flight].max
        end
        sleep 0.05
        mutex.synchronize { in_flight -= 1 }
        texts.map { |t| [t.bytesize] }
      end

      t1 = Thread.new { cached_provider.embed_batch(%w[alpha beta]) }
      t2 = Thread.new { cached_provider.embed_batch(%w[gamma delta]) }
      t1.value
      t2.value

      expect(max_in_flight).to eq(2)
    end

    it 'only fetches overlapping texts once across racing batches' do
      call_log = Queue.new
      release = Queue.new

      allow(provider).to receive(:embed_batch) do |texts|
        call_log << texts.dup
        release.pop
        texts.map { |t| [t.bytesize] }
      end

      # t1 enters first and claims 'one' + 'shared'.
      t1 = Thread.new { cached_provider.embed_batch(%w[one shared]) }
      first_call = call_log.pop
      expect(first_call).to eq(%w[one shared]) # sanity

      # t2 starts while t1 is still in the provider call. With single-flight,
      # t2 should claim only 'two' and wait on t1's entry for 'shared'.
      t2 = Thread.new { cached_provider.embed_batch(%w[shared two]) }
      sleep 0.1 # let t2 register its claim / reach the provider

      # Release any waiting provider calls (plenty of tokens).
      3.times { release << :go }

      r1 = t1.value
      r2 = t2.value

      remaining = []
      remaining << call_log.pop until call_log.empty?

      # Exactly one follow-on provider call, for the non-shared text only.
      expect(remaining).to eq([['two']])
      expect(r1).to eq([[3], [6]])              # 'one'=3, 'shared'=6
      expect(r2).to eq([[6], [3]])              # 'shared' reused, 'two'=3
    end

    it 'propagates exceptions to waiting threads instead of blocking forever' do
      call_mutex = Mutex.new
      call_count = 0
      started = Queue.new
      release = Queue.new

      allow(provider).to receive(:embed_batch) do |_texts|
        call_mutex.synchronize { call_count += 1 }
        started << :go
        release.pop
        raise 'provider down'
      end

      threads = Array.new(3) do
        Thread.new do
          cached_provider.embed_batch(%w[err-text])
        rescue StandardError => e
          e
        end
      end

      started.pop
      sleep 0.05
      3.times { release << :go }

      errors = threads.map(&:value)
      expect(errors).to all(be_a(RuntimeError))
      expect(errors.map(&:message)).to all(eq('provider down'))
      expect(call_count).to eq(1) # single-flight: one call, not three
    end

    it 'cleans up the in-flight map after success so later batches re-enter cleanly' do
      allow(provider).to receive(:embed_batch) do |texts|
        texts.map { |t| [t.bytesize] }
      end

      cached_provider.embed_batch(%w[cleanup-1])
      cached_provider.embed_batch(%w[cleanup-2])

      inflight = cached_provider.instance_variable_get(:@inflight)
      expect(inflight).to be_empty
    end

    it 'cleans up the in-flight map after exception so later batches are not stuck' do
      call = 0
      allow(provider).to receive(:embed_batch) do |texts|
        call += 1
        raise 'boom' if call == 1

        texts.map { |t| [t.bytesize] }
      end

      expect { cached_provider.embed_batch(%w[retry-text]) }.to raise_error('boom')

      inflight = cached_provider.instance_variable_get(:@inflight)
      expect(inflight).to be_empty

      # Second call must re-attempt (not silently block on a stale entry) and succeed.
      expect(cached_provider.embed_batch(%w[retry-text])).to eq([[10]])
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

RSpec.describe Woods::Cache::CachedRetriever do
  let(:cache_store) { Woods::Cache::InMemory.new }
  let(:retrieval_result) do
    Woods::Retriever::RetrievalResult.new(
      context: '## User (model)\nclass User < ApplicationRecord\nend',
      sources: %w[User],
      classification: nil,
      strategy: :vector,
      tokens_used: 42,
      budget: 8000,
      trace: nil
    )
  end
  let(:retriever) { instance_double(Woods::Retriever) }
  let(:cached_retriever) do
    described_class.new(retriever: retriever, cache_store: cache_store, context_ttl: 900)
  end

  describe '#retrieve' do
    it 'delegates to the real retriever on cache miss' do
      allow(retriever).to receive(:retrieve)
        .with('How does User work?', budget: 8000, types: nil, exclude_types: nil)
        .and_return(retrieval_result)

      result = cached_retriever.retrieve('How does User work?')

      expect(result.context).to eq(retrieval_result.context)
      expect(retriever).to have_received(:retrieve).once
    end

    it 'returns cached result on cache hit' do
      allow(retriever).to receive(:retrieve)
        .with('How does User work?', budget: 8000, types: nil, exclude_types: nil)
        .and_return(retrieval_result)

      cached_retriever.retrieve('How does User work?')
      result = cached_retriever.retrieve('How does User work?')

      expect(result.context).to eq(retrieval_result.context)
      expect(result.strategy).to eq(:vector)
      expect(result.tokens_used).to eq(42)
      expect(retriever).to have_received(:retrieve).once
    end

    it 'caches different queries independently' do
      result_a = Woods::Retriever::RetrievalResult.new(
        context: 'A', sources: [], classification: nil,
        strategy: :vector, tokens_used: 10, budget: 8000, trace: nil
      )
      result_b = Woods::Retriever::RetrievalResult.new(
        context: 'B', sources: [], classification: nil,
        strategy: :keyword, tokens_used: 20, budget: 8000, trace: nil
      )

      allow(retriever).to receive(:retrieve)
        .with('query A', budget: 8000, types: nil, exclude_types: nil).and_return(result_a)
      allow(retriever).to receive(:retrieve)
        .with('query B', budget: 8000, types: nil, exclude_types: nil).and_return(result_b)

      cached_retriever.retrieve('query A')
      cached_retriever.retrieve('query B')

      expect(retriever).to have_received(:retrieve).twice
    end

    it 'treats different budgets as different cache keys' do
      result_small = Woods::Retriever::RetrievalResult.new(
        context: 'small', sources: [], classification: nil,
        strategy: :vector, tokens_used: 5, budget: 2000, trace: nil
      )
      result_large = Woods::Retriever::RetrievalResult.new(
        context: 'large', sources: [], classification: nil,
        strategy: :vector, tokens_used: 50, budget: 16_000, trace: nil
      )

      allow(retriever).to receive(:retrieve)
        .with('query', budget: 2000, types: nil, exclude_types: nil).and_return(result_small)
      allow(retriever).to receive(:retrieve)
        .with('query', budget: 16_000, types: nil, exclude_types: nil).and_return(result_large)

      r1 = cached_retriever.retrieve('query', budget: 2000)
      r2 = cached_retriever.retrieve('query', budget: 16_000)

      expect(r1.context).to eq('small')
      expect(r2.context).to eq('large')
    end

    # Regression — the type filter kwargs must participate in the cache key,
    # otherwise a narrow `types: ["service"]` lookup returns a previously
    # cached broad result.
    it 'treats different types: filters as different cache keys' do
      result_svc = Woods::Retriever::RetrievalResult.new(
        context: 'svc', sources: [], classification: nil,
        strategy: :vector, tokens_used: 5, budget: 8000, trace: nil
      )
      result_all = Woods::Retriever::RetrievalResult.new(
        context: 'all', sources: [], classification: nil,
        strategy: :vector, tokens_used: 50, budget: 8000, trace: nil
      )

      allow(retriever).to receive(:retrieve)
        .with('q', budget: 8000, types: %w[service], exclude_types: nil).and_return(result_svc)
      allow(retriever).to receive(:retrieve)
        .with('q', budget: 8000, types: nil, exclude_types: nil).and_return(result_all)

      svc = cached_retriever.retrieve('q', types: %w[service])
      all = cached_retriever.retrieve('q')

      expect(svc.context).to eq('svc')
      expect(all.context).to eq('all')
    end

    it 'exposes wrapped stores for MCP reload' do
      vector_store = double('VectorStore')
      metadata_store = double('MetadataStore')
      graph_store = double('GraphStore')
      allow(retriever).to receive(:vector_store).and_return(vector_store)
      allow(retriever).to receive(:metadata_store).and_return(metadata_store)
      allow(retriever).to receive(:graph_store).and_return(graph_store)

      expect(cached_retriever.vector_store).to be(vector_store)
      expect(cached_retriever.metadata_store).to be(metadata_store)
      expect(cached_retriever.graph_store).to be(graph_store)
    end
  end

  # Regression — if reload refreshes the retriever's stores but leaves the
  # context cache alone, codebase_retrieve returns cached results from the
  # previous embed run until their TTL expires. Drop the :context namespace
  # entries on reload so the next retrieve goes through the fresh pipeline.
  describe '#invalidate_context_cache!' do
    it 'clears only the :context cache namespace' do
      allow(cache_store).to receive(:clear)

      cached_retriever.invalidate_context_cache!

      expect(cache_store).to have_received(:clear).with(namespace: :context)
    end

    it 'rescues and warns instead of propagating cache backend errors' do
      allow(cache_store).to receive(:clear).and_raise(StandardError, 'redis down')

      expect { cached_retriever.invalidate_context_cache! }
        .to output(/context-cache invalidation failed/).to_stderr
    end
  end
end

# ── RedisCacheStore ────────────────────────────────────────────────────

RSpec.describe Woods::Cache::RedisCacheStore do
  # Stub Redis classes so specs don't require the redis gem
  before do
    stub_const('Redis::BaseError', Class.new(StandardError)) unless defined?(Redis::BaseError)
    stub_const('Redis', Class.new) unless defined?(Redis)
  end

  let(:redis_double) { double('Redis') }
  let(:store) { described_class.new(redis: redis_double) }

  describe 'JSON round-trip' do
    it 'writes JSON and parses on read' do
      allow(redis_double).to receive(:set)
      allow(redis_double).to receive(:get).with('k').and_return('[0.1,0.2]')

      store.write('k', [0.1, 0.2])
      expect(store.read('k')).to eq([0.1, 0.2])
    end

    it 'returns nil for missing keys' do
      allow(redis_double).to receive(:get).with('k').and_return(nil)
      expect(store.read('k')).to be_nil
    end
  end

  describe 'TTL passthrough' do
    it 'passes ex: when ttl is provided' do
      allow(redis_double).to receive(:set)
      store.write('k', 'v', ttl: 3600)
      expect(redis_double).to have_received(:set).with('k', '"v"', ex: 3600)
    end

    it 'passes ex: when default_ttl is set' do
      store_with_ttl = described_class.new(redis: redis_double, default_ttl: 7200)
      allow(redis_double).to receive(:set)
      store_with_ttl.write('k', 'v')
      expect(redis_double).to have_received(:set).with('k', '"v"', ex: 7200)
    end

    it 'omits ex: when no ttl' do
      allow(redis_double).to receive(:set)
      store.write('k', 'v')
      expect(redis_double).to have_received(:set).with('k', '"v"')
    end
  end

  describe 'connection error degradation' do
    it 'returns nil on read failure' do
      allow(redis_double).to receive(:get).and_raise(Errno::ECONNREFUSED)
      expect(store.read('k')).to be_nil
    end

    it 'returns nil on write failure' do
      allow(redis_double).to receive(:set).and_raise(Errno::ECONNRESET)
      expect(store.write('k', 'v')).to be_nil
    end

    it 'returns nil on delete failure' do
      allow(redis_double).to receive(:del).and_raise(Errno::ECONNREFUSED)
      expect(store.delete('k')).to be_nil
    end

    it 'returns false on exist? failure' do
      allow(redis_double).to receive(:exists?).and_raise(Errno::ECONNRESET)
      expect(store.exist?('k')).to be false
    end
  end

  describe 'corrupted JSON handling' do
    it 'returns nil and deletes the key' do
      allow(redis_double).to receive(:get).with('k').and_return('not-json{{{')
      allow(redis_double).to receive(:del)

      expect(store.read('k')).to be_nil
      expect(redis_double).to have_received(:del).with('k')
    end
  end
end

# ── SolidCacheStore ───────────────────────────────────────────────────

RSpec.describe Woods::Cache::SolidCacheStore do
  let(:cache_double) { instance_double('ActiveSupport::Cache::Store') }
  let(:store) { described_class.new(cache: cache_double) }

  describe 'JSON round-trip' do
    it 'writes JSON and parses on read' do
      allow(cache_double).to receive(:write)
      allow(cache_double).to receive(:read).with('k').and_return('[0.1,0.2]')

      store.write('k', [0.1, 0.2])
      expect(store.read('k')).to eq([0.1, 0.2])
    end

    it 'returns nil for missing keys' do
      allow(cache_double).to receive(:read).with('k').and_return(nil)
      expect(store.read('k')).to be_nil
    end
  end

  describe 'TTL passthrough' do
    it 'passes expires_in: when ttl is provided' do
      allow(cache_double).to receive(:write)
      store.write('k', 'v', ttl: 3600)
      expect(cache_double).to have_received(:write).with('k', '"v"', expires_in: 3600)
    end

    it 'passes expires_in: when default_ttl is set' do
      store_with_ttl = described_class.new(cache: cache_double, default_ttl: 7200)
      allow(cache_double).to receive(:write)
      store_with_ttl.write('k', 'v')
      expect(cache_double).to have_received(:write).with('k', '"v"', expires_in: 7200)
    end

    it 'omits expires_in: when no ttl' do
      allow(cache_double).to receive(:write)
      store.write('k', 'v')
      expect(cache_double).to have_received(:write).with('k', '"v"')
    end
  end

  describe 'connection error degradation' do
    it 'returns nil on read failure' do
      allow(cache_double).to receive(:read).and_raise(StandardError, 'connection lost')
      expect(store.read('k')).to be_nil
    end

    it 'returns nil on write failure' do
      allow(cache_double).to receive(:write).and_raise(StandardError, 'connection lost')
      expect(store.write('k', 'v')).to be_nil
    end

    it 'returns nil on delete failure' do
      allow(cache_double).to receive(:delete).and_raise(StandardError, 'connection lost')
      expect(store.delete('k')).to be_nil
    end

    it 'returns false on exist? failure' do
      allow(cache_double).to receive(:exist?).and_raise(StandardError, 'connection lost')
      expect(store.exist?('k')).to be false
    end
  end

  describe 'corrupted JSON handling' do
    it 'returns nil and deletes the key' do
      allow(cache_double).to receive(:read).with('k').and_return('not-json{{{')
      allow(cache_double).to receive(:delete)

      expect(store.read('k')).to be_nil
      expect(cache_double).to have_received(:delete).with('k')
    end
  end
end

# ── DEFAULT_TTLS ───────────────────────────────────────────────────────

RSpec.describe 'Woods::Cache::DEFAULT_TTLS' do
  it 'defines all expected domains' do
    expect(Woods::Cache::DEFAULT_TTLS.keys).to contain_exactly(
      :embeddings, :metadata, :structural, :search, :context
    )
  end

  it 'has positive integer values for all domains' do
    Woods::Cache::DEFAULT_TTLS.each_value do |ttl|
      expect(ttl).to be_a(Integer)
      expect(ttl).to be > 0
    end
  end

  it 'is frozen' do
    expect(Woods::Cache::DEFAULT_TTLS).to be_frozen
  end
end
