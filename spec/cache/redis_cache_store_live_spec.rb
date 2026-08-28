# frozen_string_literal: true

# Real-Redis contract specs for {Woods::Cache::RedisCacheStore} (#220 pattern).
#
# The unit specs drive the store through a Redis double, which verifies the
# commands it *builds* but not what a real server does with them — TTL
# semantics, SCAN paging, and connection refusal are server behavior. This file
# mirrors spec/integration/live_backends_spec.rb: same :live_backends gate, so
# it is excluded from the default suite and opts in through
# WOODS_RUN_LIVE_BACKENDS=1 with a reachable server:
#
#   WOODS_REDIS_URL=redis://localhost:6379/0
#
# The live-backends CI lane provides the service (redis:7-alpine) and installs
# the redis client gem with `bundle add redis` before running, since no
# repository bundle carries it.
#
# NOTE: the require is load-guarded because the default suite still *loads*
# every spec file (tag filters apply at example selection), and requiring an
# uninstalled gem there would crash the whole run.

require 'spec_helper'
require 'securerandom'
require 'woods/cache/redis_cache_store'

begin
  require 'redis'
rescue LoadError
  nil
end

RSpec.describe Woods::Cache::RedisCacheStore, :live_backends do
  let(:redis_url) { ENV.fetch('WOODS_REDIS_URL', 'redis://127.0.0.1:6379/0') }
  let(:redis) do
    raise LoadError, 'the redis client gem is required for the live Redis specs' unless defined?(Redis)

    Redis.new(url: redis_url)
  end
  let(:store) { described_class.new(redis: redis) }

  # CacheStore#logger falls back to a stderr logger outside Rails; the
  # connection-failure examples below exercise it, so route it to the void.
  before { stub_const('Rails', double('Rails', logger: Logger.new(IO::NULL))) }

  # Every example keys under a unique prefix, so examples cannot collide with
  # each other or with a concurrent run. Keys built outside the woods:spec
  # family (the namespace-clear example writes through the store's own
  # woods:cache:* convention) must be tracked explicitly, so cleanup records
  # every key at creation and deletes exactly those afterwards.
  def track(key)
    (@tracked_keys ||= []) << key
    key
  end

  def key(suffix)
    track("woods:spec:#{SecureRandom.hex(6)}:#{suffix}")
  end

  after do
    tracked = Array(@tracked_keys)
    redis.del(*tracked) if tracked.any?

    # Belt and braces for the woods:spec family, in case a key was built
    # without going through track().
    cursor = '0'
    loop do
      cursor, keys = redis.scan(cursor, match: 'woods:spec:*', count: 100)
      redis.del(*keys) if keys.any?
      break if cursor == '0'
    end

    # The backends below are shared CI/dev servers: a leaked key is test
    # state retention, so cleanup failure fails the example.
    survivors = tracked.select { |k| redis.exists?(k) }
    expect(survivors).to be_empty, "leftover test keys in the shared Redis: #{survivors.join(', ')}"
  end

  describe 'JSON round-trip against a real server' do
    it 'stores and retrieves a string' do
      k = key('string')

      store.write(k, 'hello')

      expect(store.read(k)).to eq('hello')
    end

    it 'stores and retrieves an array of floats' do
      k = key('vector')

      store.write(k, [0.1, 0.2, 0.3])

      expect(store.read(k)).to eq([0.1, 0.2, 0.3])
    end

    it 'stores and retrieves a hash' do
      k = key('metadata')

      store.write(k, { 'type' => 'model', 'identifier' => 'User' })

      expect(store.read(k)).to eq('type' => 'model', 'identifier' => 'User')
    end

    it 'returns nil for a missing key' do
      expect(store.read(key('absent'))).to be_nil
    end
  end

  describe 'existence and deletion' do
    it 'reports existence and removes keys' do
      k = key('exist')

      expect(store.exist?(k)).to be(false)
      store.write(k, 'value')
      expect(store.exist?(k)).to be(true)
      store.delete(k)
      expect(store.exist?(k)).to be(false)
    end
  end

  describe 'TTL expiry' do
    it 'lets a real server expire an entry written with ttl:' do
      k = key('ttl')
      store.write(k, 'ephemeral', ttl: 1)
      expect(store.read(k)).to eq('ephemeral')

      sleep 1.3

      expect(store.read(k)).to be_nil
      expect(store.exist?(k)).to be(false)
    end

    it 'applies default_ttl when the write omits one' do
      k = key('default_ttl')
      defaulting_store = described_class.new(redis: redis, default_ttl: 2)

      defaulting_store.write(k, 'expires-later')

      expect(redis.ttl(k)).to(satisfy { |seconds| seconds.positive? && seconds <= 2 })
    end

    it 'writes without expiry when neither ttl nor default_ttl is set' do
      k = key('persistent')
      store.write(k, 'stays')

      expect(redis.ttl(k)).to eq(-1)
    end
  end

  describe '#clear with a namespace' do
    # clear() only touches keys built with the store's own naming convention
    # (woods:cache:<namespace>:*), so the example must write through that
    # convention for the scoping assertion to mean anything. Those keys sit
    # outside the woods:spec sweep pattern, hence the explicit tracking.
    it 'clears only the matching namespace' do
      embeddings = track(Woods::Cache.cache_key(:embeddings, SecureRandom.hex(6)))
      context = track(Woods::Cache.cache_key(:context, SecureRandom.hex(6)))
      store.write(embeddings, 'v1')
      store.write(context, 'v2')

      store.clear(namespace: :embeddings)

      expect(store.read(embeddings)).to be_nil
      expect(store.read(context)).to eq('v2')
    end
  end

  describe 'connection failure' do
    # Port 1 refuses immediately, so no example waits on a timeout; the store
    # must degrade (log + nil/false) rather than raise into the caller.
    let(:unreachable_store) do
      described_class.new(redis: Redis.new(url: 'redis://127.0.0.1:1', reconnect_attempts: 0))
    end

    it 'returns nil on read' do
      expect(unreachable_store.read(key('down'))).to be_nil
    end

    it 'returns nil on write' do
      expect(unreachable_store.write(key('down'), 'v')).to be_nil
    end

    it 'returns false on exist?' do
      expect(unreachable_store.exist?(key('down'))).to be(false)
    end
  end
end
