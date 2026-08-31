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
