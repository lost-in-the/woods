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

# Thread-safe fake used by the concurrent specs for {CachedEmbeddingProvider}.
# rspec-mocks' proxy.rb `message_received` mutates internal state without
# synchronization and drops calls when invoked from multiple threads under MRI's
# 3.1/3.2 scheduler — which CI exposed via flaky failures on those two Ruby
# versions (#94). This plain object routes every call to its constructor block
# deterministically, so the concurrency assertions are meaningful.
#
# Lives at the top level so rubocop's Lint/ConstantDefinitionInBlock is happy
# (constants defined inside an `RSpec.describe` block would warn).
#
# @api private
class FakeEmbeddingProvider
  attr_reader :dimensions, :model_name

  def initialize(embed: nil, embed_batch: nil, dimensions: 768, model_name: 'test-model')
    @embed_block = embed
    @embed_batch_block = embed_batch
    @dimensions = dimensions
    @model_name = model_name
  end

  def embed(text)
    raise NoMethodError, 'embed not stubbed' unless @embed_block

    @embed_block.call(text)
  end

  def embed_batch(texts)
    raise NoMethodError, 'embed_batch not stubbed' unless @embed_batch_block

    @embed_batch_block.call(texts)
  end
end

RSpec.describe Woods::Cache::CachedEmbeddingProvider do
  let(:cache_store) { Woods::Cache::InMemory.new }
  let(:provider) do
    double('EmbeddingProvider',
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

    it 'does not serve one model\'s cached vector to a different model' do
      # A shared persistent backend must not hand a switched/upgraded model
      # the previous model's vector for the same text.
      allow(provider).to receive(:embed).with('hello').and_return([0.1, 0.2])
      cached_provider.embed('hello')

      other_provider = double('EmbeddingProvider', dimensions: 1536, model_name: 'other-model')
      allow(other_provider).to receive(:embed).with('hello').and_return([0.9, 0.8, 0.7])
      other_cached = described_class.new(provider: other_provider, cache_store: cache_store, ttl: 3600)

      result = other_cached.embed('hello')

      expect(result).to eq([0.9, 0.8, 0.7])
      expect(other_provider).to have_received(:embed).once
    end

    it 'builds the cache key without probing provider#dimensions (no network on lookup)' do
      # For Ollama, #dimensions performs a live embed('test'); keying on it
      # made every cache hit depend on the backend being reachable. The key
      # must use model_name (a plain attribute) only.
      probing_provider = double('EmbeddingProvider', model_name: 'test-model')
      allow(probing_provider).to receive(:dimensions).and_raise('network down')
      allow(probing_provider).to receive(:embed).with('hello').and_return([0.1, 0.2])
      cached = described_class.new(provider: probing_provider, cache_store: cache_store, ttl: 3600)

      expect { cached.embed('hello') }.not_to raise_error # miss: stores
      expect(cached.embed('hello')).to eq([0.1, 0.2]) # hit: reads
      expect(probing_provider).not_to have_received(:dimensions)
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
  # quota and tripping rate limits. Each spec drives a stampede with deterministic
  # queue + waiter_count synchronization (NOT Thread#status polling — which briefly
  # reports `sleep` during routine mutex contention inside cache_store.read and
  # caused CI flakes on MRI 3.1/3.2, see #94).
  describe '#embed_batch single-flight under concurrent misses' do
    # Poll the CachedEmbeddingProvider's inflight map for an entry on `text` with
    # exactly `expected` waiters blocked in {InflightEntry#await}. This is the
    # authoritative "N threads have actually attached as waiters" barrier.
    def wait_for_waiters(cached, text, expected, timeout: 2.0)
      deadline = Time.now + timeout
      loop do
        entry = cached.instance_variable_get(:@inflight)[text]
        break if entry && entry.waiter_count >= expected
        raise "timeout waiting for #{expected} waiters on #{text.inspect}" if Time.now > deadline

        Thread.pass
      end
    end

    it 'deduplicates provider calls when N threads miss on the same texts' do
      call_mutex = Mutex.new
      call_count = 0
      entered = Queue.new
      release = Queue.new

      provider = FakeEmbeddingProvider.new(embed_batch: lambda do |texts|
        call_mutex.synchronize { call_count += 1 }
        entered << :go
        release.pop
        texts.map { |t| [t.bytesize] }
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      thread_count = 5
      threads = Array.new(thread_count) do
        Thread.new { cached.embed_batch(%w[shared-a shared-b]) }
      end

      entered.pop # one thread is now in the provider call as owner
      # Non-owner threads enter `await_others` which blocks serially on each
      # entry in `awaiting`. They all park on the FIRST shared key first, so
      # waiting for N-1 waiters on 'shared-a' is sufficient to know every
      # non-owner thread has attached. ('shared-b' gets its waiters only after
      # 'shared-a' fulfills, which happens after `release << :go`.)
      wait_for_waiters(cached, 'shared-a', thread_count - 1)

      release << :go
      results = threads.map(&:value)

      expect(call_count).to eq(1)
      expect(results).to all(eq([[8], [8]])) # 'shared-a'.bytesize == 8
    end

    it 'parallelizes disjoint batches instead of serializing on a global lock' do
      entered = Queue.new
      release = Queue.new
      call_count = 0
      call_mutex = Mutex.new

      provider = FakeEmbeddingProvider.new(embed_batch: lambda do |texts|
        call_mutex.synchronize { call_count += 1 }
        entered << :go
        release.pop
        texts.map { |t| [t.bytesize] }
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      t1 = Thread.new { cached.embed_batch(%w[alpha beta]) }
      t2 = Thread.new { cached.embed_batch(%w[gamma delta]) }

      # Both provider calls must be in flight simultaneously. Popping twice from
      # `entered` blocks until BOTH threads reached the provider block — proving
      # the fix didn't accidentally introduce a global lock that serializes them.
      2.times { entered.pop }
      expect(call_count).to eq(2)

      2.times { release << :go }
      t1.value
      t2.value
    end

    it 'only fetches overlapping texts once across racing batches' do
      call_log = Queue.new
      release = Queue.new

      provider = FakeEmbeddingProvider.new(embed_batch: lambda do |texts|
        call_log << texts.dup
        release.pop
        texts.map { |t| [t.bytesize] }
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      t1 = Thread.new { cached.embed_batch(%w[one shared]) }
      first_call = call_log.pop # t1 is now in provider holding 'one'+'shared'
      expect(first_call).to eq(%w[one shared])

      # With t1 holding 'shared', t2's 'shared' miss goes into `awaiting`; 'two'
      # is disjoint, so t2 becomes the owner of a second provider call for `['two']`
      # alone. `call_log.pop` unblocks only when t2 actually enters the provider —
      # so it's both the synchronization barrier AND the assertion.
      t2 = Thread.new { cached.embed_batch(%w[shared two]) }
      second_call = call_log.pop                 # t2 entered the provider for 'two'
      expect(second_call).to eq(['two'])

      2.times { release << :go }
      r1 = t1.value
      r2 = t2.value

      expect(call_log).to be_empty
      expect(r1).to eq([[3], [6]])               # 'one'=3, 'shared'=6
      expect(r2).to eq([[6], [3]])               # 'shared' reused, 'two'=3
    end

    it 'propagates exceptions to waiting threads instead of blocking forever' do
      call_mutex = Mutex.new
      call_count = 0
      entered = Queue.new
      release = Queue.new

      provider = FakeEmbeddingProvider.new(embed_batch: lambda do |_texts|
        call_mutex.synchronize { call_count += 1 }
        entered << :go
        release.pop
        raise 'provider down'
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      threads = Array.new(3) do
        Thread.new do
          cached.embed_batch(%w[err-text])
        rescue StandardError => e
          e
        end
      end

      entered.pop                                # owner is in the provider
      wait_for_waiters(cached, 'err-text', threads.size - 1)

      release << :go
      errors = threads.map(&:value)

      expect(errors).to all(be_a(RuntimeError))
      expect(errors.map(&:message)).to all(eq('provider down'))
      expect(call_count).to eq(1) # single-flight: one call, not three
    end

    # Behavioral proof that the inflight map is cleared after a successful call:
    # a second batch on the SAME text, with a stub that only returns one result,
    # would hang or crash if a stale entry were left behind.
    it 'allows a later batch on the same text to re-enter the provider' do
      call_count = 0
      allow(provider).to receive(:embed_batch) do |texts|
        call_count += 1
        texts.map { |t| [t.bytesize + call_count] }
      end

      first = cached_provider.embed_batch(%w[same])
      cache_store.clear # force a miss so the second call re-enters the provider
      second = cached_provider.embed_batch(%w[same])

      expect(first).to eq([[5]])  # bytesize 4 + call_count 1
      expect(second).to eq([[6]]) # bytesize 4 + call_count 2
      expect(call_count).to eq(2) # re-entered the provider cleanly
    end

    # Regression for the same invariant across the exception path — if the owner's
    # provider call raises, a subsequent batch for the same text must re-attempt
    # (not silently block on a stale inflight entry).
    it 'allows a later batch on the same text to re-enter after owner exception' do
      call = 0
      allow(provider).to receive(:embed_batch) do |texts|
        call += 1
        raise 'boom' if call == 1

        texts.map { |t| [t.bytesize] }
      end

      expect { cached_provider.embed_batch(%w[retry-text]) }.to raise_error('boom')

      expect(cached_provider.embed_batch(%w[retry-text])).to eq([[10]])
      expect(call).to eq(2)
    end

    # Hardening for the "owner aborted mid-fulfill" path flagged in review. A
    # non-StandardError exception (Interrupt, NoMemoryError) raised between
    # iterations of the fulfill loop would previously leak inflight entries and
    # block waiters forever. The `ensure` wrap in fetch_and_fulfill rejects any
    # entry not yet fulfilled with OwnerAbortedError.
    it 'recovers from an Interrupt raised mid-fulfill and re-enters cleanly' do
      allow(provider).to receive(:embed_batch) do |texts|
        texts.map { |t| [t.bytesize] }
      end

      # Simulate a Ctrl-C / Thread#kill between fulfills by raising Interrupt
      # from write_cache on the second iteration. The `ensure` wrap must still
      # clear the inflight map so the retry below reaches the provider.
      abort_after = 0
      cached_provider.define_singleton_method(:write_cache) do |_text, _vector|
        abort_after += 1
        raise Interrupt if abort_after == 2
      end

      expect { cached_provider.embed_batch(%w[ok1 ok2 ok3]) }.to raise_error(Interrupt)

      # Remove the override so the follow-up batch uses the real write_cache.
      class << cached_provider
        remove_method :write_cache
      end

      expect(cached_provider.embed_batch(%w[ok3])).to eq([[3]])
    end

    # Regression for the C2 concern from the concurrency review — a provider that
    # returns fewer vectors than texts would previously fulfill waiters with `nil`.
    it 'raises on malformed provider response and rejects waiters' do
      allow(provider).to receive(:embed_batch) do |texts|
        texts.take(texts.size - 1).map { |t| [t.bytesize] } # drop the last vector
      end

      expect { cached_provider.embed_batch(%w[a b]) }
        .to raise_error(ArgumentError, /returned 1 vectors for 2 texts/)
    end
  end

  # Regression — round-5 audit X-1 / issue #88 (N1 follow-up). The #embed single-
  # text path shares the same inflight map as #embed_batch, so concurrent callers
  # for the same text produce exactly one provider call regardless of which
  # method they use.
  describe '#embed single-flight' do
    def wait_for_waiters(cached, text, expected, timeout: 2.0)
      deadline = Time.now + timeout
      loop do
        entry = cached.instance_variable_get(:@inflight)[text]
        break if entry && entry.waiter_count >= expected
        raise "timeout waiting for #{expected} waiters on #{text.inspect}" if Time.now > deadline

        Thread.pass
      end
    end

    it 'deduplicates concurrent #embed calls for the same text' do
      call_count = 0
      call_mutex = Mutex.new
      entered = Queue.new
      release = Queue.new

      provider = FakeEmbeddingProvider.new(embed: lambda do |text|
        call_mutex.synchronize { call_count += 1 }
        entered << :go
        release.pop
        [text.bytesize]
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      thread_count = 4
      threads = Array.new(thread_count) { Thread.new { cached.embed('shared') } }

      entered.pop
      wait_for_waiters(cached, 'shared', thread_count - 1)

      release << :go
      results = threads.map(&:value)

      expect(results).to all(eq([6]))
      expect(call_count).to eq(1)
    end

    it 'shares the inflight map with #embed_batch for the same text' do
      # An in-flight #embed call claims the text; a concurrent #embed_batch for
      # the same text must attach to that entry rather than making a second call.
      entered = Queue.new
      release = Queue.new
      embed_calls = 0
      batch_calls = 0

      provider = FakeEmbeddingProvider.new(
        embed: lambda do |text|
          embed_calls += 1
          entered << :go
          release.pop
          [text.bytesize + 100]
        end,
        embed_batch: lambda do |texts|
          batch_calls += 1
          texts.map { |t| [t.bytesize] }
        end
      )
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      # Force ordering: embed first becomes the owner for 'x', then embed_batch
      # attaches as a waiter (verified via waiter_count).
      embed_thread = Thread.new { cached.embed('x') }
      entered.pop                                 # embed is now in the provider

      batch_thread = Thread.new { cached.embed_batch(%w[x]) }
      wait_for_waiters(cached, 'x', 1)            # batch_thread has attached

      release << :go

      expect(embed_thread.value).to eq([101])
      expect(batch_thread.value).to eq([[101]])   # shared the owner's vector
      expect(embed_calls).to eq(1)
      expect(batch_calls).to eq(0)                # attached to owner, no second call
    end

    it 'propagates provider exception to concurrent waiters' do
      entered = Queue.new
      release = Queue.new

      provider = FakeEmbeddingProvider.new(embed: lambda do |_text|
        entered << :go
        release.pop
        raise 'embed failed'
      end)
      cached = described_class.new(provider: provider, cache_store: cache_store, ttl: 3600)

      thread_count = 3
      threads = Array.new(thread_count) do
        Thread.new do
          cached.embed('err')
        rescue StandardError => e
          e
        end
      end

      entered.pop
      wait_for_waiters(cached, 'err', thread_count - 1)

      release << :go
      errors = threads.map(&:value)

      expect(errors).to all(be_a(RuntimeError))
      expect(errors.map(&:message)).to all(eq('embed failed'))
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

    it 'round-trips type_rank_context through the cache with symbol keys preserved (#108)' do
      typed_result = Woods::Retriever::RetrievalResult.new(
        context: '## Ctx', sources: [], classification: nil,
        strategy: :vector, tokens_used: 10, budget: 8000, trace: nil,
        type_rank_context: {
          'controller' => {
            source: :in_top_k,
            top_of_type_global_rank: 2,
            global_k: 20,
            total_of_type: 183
          },
          'service' => {
            source: :within_type_fallback,
            top_of_type_global_rank: nil,
            global_k: 20,
            total_of_type: 17
          }
        }
      )
      allow(retriever).to receive(:retrieve)
        .with('typed query', budget: 8000, types: %w[controller service], exclude_types: nil)
        .and_return(typed_result)

      # Miss → fills cache.
      fresh = cached_retriever.retrieve('typed query', types: %w[controller service])
      # Hit → rehydrates from JSON-normalized store.
      hit = cached_retriever.retrieve('typed query', types: %w[controller service])

      expect(hit.type_rank_context).to eq(fresh.type_rank_context)
      expect(hit.type_rank_context['controller'][:source]).to eq(:in_top_k)
      expect(hit.type_rank_context['service'][:source]).to eq(:within_type_fallback)
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
  let(:cache_double) { double('ActiveSupport::Cache::Store') }
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
