# frozen_string_literal: true

# Real-Redis contract specs for {Woods::SessionTracer::RedisStore} (P4).
#
# The unit specs drive the store through MockRedis, which verifies the
# commands it *builds* but not what a real server does with them. The zset
# recency index is exactly that kind of change: WRONGTYPE refusal on a
# legacy SET index, score ordering, and ZRANGE windowing are server
# behavior. Mirrors spec/cache/redis_cache_store_live_spec.rb: same
# :live_backends gate, so it is excluded from the default suite and opts in
# through WOODS_RUN_LIVE_BACKENDS=1 with a reachable server:
#
#   WOODS_REDIS_URL=redis://localhost:6379/0
#
# IMPORTANT: point WOODS_REDIS_URL at a disposable Redis instance or a
# dedicated logical database. The migration example deliberately seeds a
# legacy SET at the `woods:sessions` index key and the teardown deletes the
# store's keys in the selected database.

require 'spec_helper'
require 'securerandom'
require 'woods/session_tracer/redis_store'

begin
  require 'redis'
rescue LoadError
  nil
end

RSpec.describe Woods::SessionTracer::RedisStore, :live_backends do
  let(:redis_url) { ENV.fetch('WOODS_REDIS_URL', 'redis://127.0.0.1:6379/0') }
  let(:redis) do
    raise LoadError, 'the redis client gem is required for the live Redis specs' unless defined?(Redis)

    Redis.new(url: redis_url)
  end
  let(:run_id) { SecureRandom.hex(4) }
  let(:store) { described_class.new(redis: redis) }

  let(:request_data) do
    {
      'session_id' => 'sess1',
      'timestamp' => '2026-02-13T10:30:00Z',
      'method' => 'GET',
      'path' => '/orders',
      'controller' => 'OrdersController',
      'action' => 'index',
      'status' => 200,
      'duration_ms' => 12,
      'format' => 'html'
    }
  end

  after do
    store.clear_all
    redis.del(described_class::SESSIONS_KEY)
  rescue StandardError
    nil
  end

  describe 'legacy SET reads before the first new record' do
    let(:legacy_id) { "run-#{run_id}-legacy" }
    let(:other_id) { "run-#{run_id}-other" }

    before do
      redis.sadd(described_class::SESSIONS_KEY, [legacy_id, other_id, 'expired'])
      redis.rpush(store.send(:session_key, legacy_id), JSON.generate(request_data))
      newer_request = request_data.merge('timestamp' => '2026-02-13T11:00:00Z')
      redis.rpush(store.send(:session_key, other_id), JSON.generate(newer_request))
    end

    it 'lists by payload recency, prunes expired members, and preserves old-writer compatibility' do
      expect(store.sessions(limit: 1).map { |entry| entry['session_id'] }).to eq([other_id])
      expect(redis.type(described_class::SESSIONS_KEY)).to eq('set')
      expect(redis.smembers(described_class::SESSIONS_KEY)).to contain_exactly(legacy_id, other_id)
      expect { redis.sadd(described_class::SESSIONS_KEY, 'old-writer') }.not_to raise_error
    end

    it 'clears one legacy session without deleting another' do
      store.clear(legacy_id)
      expect(store.read(legacy_id)).to eq([])
      expect(store.read(other_id).size).to eq(1)
      expect(redis.smembers(described_class::SESSIONS_KEY)).to contain_exactly(other_id, 'expired')
    end

    it 'clears all legacy lists and the index without a prior record' do
      store.clear_all
      expect(store.read(legacy_id)).to eq([])
      expect(store.read(other_id)).to eq([])
      expect(redis.exists?(described_class::SESSIONS_KEY)).to be(false)
      expect(store.sessions).to eq([])
    end

    it 'prunes expired members after a writer converts the index between list and cleanup' do
      writer_redis = Redis.new(url: redis_url)
      writer = described_class.new(redis: writer_redis)
      converted = false
      allow(redis).to receive(:exists?).and_wrap_original do |method, key|
        unless converted
          converted = true
          writer.record('fresh', request_data)
        end
        method.call(key)
      end

      expect(store.sessions.map { |entry| entry['session_id'] }).to contain_exactly(legacy_id, other_id)
      expect(redis.zrange(described_class::SESSIONS_KEY, 0, -1)).to contain_exactly(legacy_id, other_id, 'fresh')
      expect(store.read('fresh').size).to eq(1)
    ensure
      writer_redis&.close
    end

    it 'evicts migrated score-zero members lexically until they are recorded again' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      redis.srem(described_class::SESSIONS_KEY, 'expired')
      newest_request = request_data.merge('timestamp' => '2026-02-13T12:00:00Z')
      redis.rpush(store.send(:session_key, legacy_id), JSON.generate(newest_request))
      bounded.record('fresh', request_data)

      expect(bounded.read(legacy_id)).to eq([])
      expect(bounded.read(other_id).size).to eq(1)
      expect(redis.zscore(described_class::SESSIONS_KEY, other_id)).to eq(0.0)
    end
  end

  describe 'recency zset index' do
    it 'keeps the index as a zset and round-trips records' do
      store.record("run-#{run_id}-a", request_data)

      expect(redis.type(described_class::SESSIONS_KEY)).to eq('zset')
      expect(store.read("run-#{run_id}-a").first['controller']).to eq('OrdersController')
    end

    it 'evicts the session with the oldest request timestamp, not the first written' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      bounded.record("run-#{run_id}-newest", request_data.merge('timestamp' => '2026-02-13T12:00:00Z'))
      bounded.record("run-#{run_id}-oldest", request_data.merge('timestamp' => '2026-02-13T09:00:00Z'))
      bounded.record("run-#{run_id}-middle", request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))

      expect(store.read("run-#{run_id}-oldest")).to eq([])
      expect(store.read("run-#{run_id}-newest").size).to eq(1)
      expect(store.read("run-#{run_id}-middle").size).to eq(1)
    end

    it 'lists sessions most-recent first' do
      ids = ["run-#{run_id}-oldest", "run-#{run_id}-newest", "run-#{run_id}-middle"]
      stamps = ['2026-02-13T10:00:00Z', '2026-02-13T12:00:00Z', '2026-02-13T11:00:00Z']

      ids.zip(stamps).each { |(id, stamp)| store.record(id, request_data.merge('timestamp' => stamp)) }

      expect(store.sessions.map { |s| s['session_id'] }).to eq(
        ["run-#{run_id}-newest", "run-#{run_id}-middle", "run-#{run_id}-oldest"]
      )
    end

    it 'migrates a legacy set-based index on first record' do
      redis.sadd(described_class::SESSIONS_KEY, "run-#{run_id}-legacy")
      redis.del("woods:session:run-#{run_id}-legacy")

      store.record("run-#{run_id}-fresh", request_data)

      expect(redis.type(described_class::SESSIONS_KEY)).to eq('zset')
      summaries = store.sessions.map { |s| s['session_id'] }
      expect(summaries).to include("run-#{run_id}-fresh")
    end

    # Two writers racing a legacy index through real concurrent
    # connections: the atomic script guarantees every member survives any
    # interleaving, so run the pair repeatedly.
    it 'survives a two-client migration race with every session indexed' do
      5.times do |attempt|
        key = described_class::SESSIONS_KEY
        redis.del(key)
        redis.sadd(key, "run-#{run_id}-legacy-#{attempt}")
        redis.del("woods:session:run-#{run_id}-legacy-#{attempt}")

        store_a = described_class.new(redis: Redis.new(url: redis_url))
        store_b = described_class.new(redis: Redis.new(url: redis_url))
        id_a = "run-#{run_id}-a#{attempt}"
        id_b = "run-#{run_id}-b#{attempt}"

        threads = [
          Thread.new { store_a.record(id_a, request_data) },
          Thread.new { store_b.record(id_b, request_data) }
        ]
        threads.each(&:join)

        indexed = redis.zrange(key, 0, -1)
        expect(indexed).to include("run-#{run_id}-legacy-#{attempt}", id_a, id_b)
        expect(store_a.read(id_a).size).to eq(1)
        expect(store_b.read(id_b).size).to eq(1)

        store_a.clear(id_a)
        store_b.clear(id_b)
        store_a.clear("run-#{run_id}-legacy-#{attempt}")
      end
    end

    it 'clears a single session and the whole index' do
      store.record("run-#{run_id}-a", request_data)
      store.record("run-#{run_id}-b", request_data)
      store.clear("run-#{run_id}-a")

      expect(store.read("run-#{run_id}-a")).to eq([])
      expect(store.read("run-#{run_id}-b").size).to eq(1)

      store.clear_all
      expect(store.sessions).to eq([])
    end
  end
end
