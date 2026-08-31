# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/session_tracer/redis_store'

# Mirrors the redis client's type-refusal errors (Redis::CommandError /
# Redis::WrongTypeError, depending on gem generation). Named with the Redis
# prefix so the store's client-error class check matches.
class RedisTestCommandError < StandardError; end

# Minimal in-memory Redis mock for unit testing.
# Implements only the subset of Redis commands used by RedisStore.
class MockRedis
  attr_reader :data

  def initialize
    @data = {}
  end

  def rpush(key, value)
    @data[key] ||= []
    @data[key] << value
    @data[key].size
  end

  def lrange(key, start, stop)
    list = @data[key] || []
    stop = list.size - 1 if stop == -1
    list[start..stop] || []
  end

  # rubocop:disable-next Naming/PredicateMethod
  def ltrim(key, start, stop)
    list = @data[key] || []
    start = [list.size + start, 0].max if start.negative?
    stop = list.size + stop if stop.negative?
    @data[key] = list[start..stop] || []
    true
  end

  # rubocop:disable-next Naming/PredicateMethod
  def expire(_key, _seconds)
    # No-op for tests (TTL not simulated)
    true
  end

  def sadd(key, member)
    @data[key] ||= []
    return if @data[key].include?(member)

    @data[key] << member
    true
  end

  def smembers(key)
    @data[key] || []
  end

  def srem(key, member)
    (@data[key] || []).delete(member)
  end

  def exists?(key)
    @data.key?(key) && !@data[key].nil?
  end

  def del(key)
    @data.delete(key)
    1
  end

  # ── sorted-set commands (session recency index) ──────────────────────

  # rubocop:disable-next Naming/PredicateMethod
  def zadd(key, score, member)
    ensure_zset(key)
    (@data[key] ||= {})[member] = score.to_f
    true
  end

  def zrange(key, start, stop)
    ensure_zset(key)
    members = (@data[key] || {}).sort_by { |member, score| [score, member] }.map(&:first)
    stop = members.size - 1 if stop == -1
    members[start..stop] || []
  end

  def zrem(key, member)
    ensure_zset(key)
    (@data[key] || {}).delete(member)
    1
  end

  def zcard(key)
    ensure_zset(key)
    (@data[key] || {}).size
  end

  # Emulates the store's recency-index script — the only script the suite
  # sends — as a single step: type check, legacy-member transfer, insertion.
  # The live-Redis spec exercises the real Lua against a real server.
  def eval(script, keys: [], argv: [])
    unless script == Woods::SessionTracer::RedisStore::INDEX_UPDATE_SCRIPT
      raise ArgumentError, 'MockRedis only implements the Woods recency-index script'
    end

    key = keys.fetch(0)
    score = argv.fetch(0).to_f
    member = argv.fetch(1)

    case @data[key]
    when Array
      legacy = @data.delete(key)
      @data[key] = {}
      legacy.each { |m| @data[key][m] = 0.0 }
    when nil
      @data[key] = {}
    end
    @data[key][member] = score
    1
  end

  # A set is an Array here and a zset a Hash, mirroring how the real server
  # refuses cross-type commands.
  def ensure_zset(key)
    existing = @data[key]
    return if existing.nil? || existing.is_a?(Hash)

    raise RedisTestCommandError, 'WRONGTYPE Operation against a key holding the wrong kind of value'
  end
end

# Pretend Redis is defined so RedisStore doesn't raise
Redis = MockRedis unless defined?(Redis)

RSpec.describe Woods::SessionTracer::RedisStore do
  let(:redis) { MockRedis.new }
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

  describe '#record and #read' do
    it 'records and reads back a single request' do
      store.record('sess1', request_data)
      results = store.read('sess1')

      expect(results.size).to eq(1)
      expect(results[0]['controller']).to eq('OrdersController')
    end

    it 'appends multiple requests in order' do
      store.record('sess1', request_data.merge('action' => 'index'))
      store.record('sess1', request_data.merge('action' => 'create'))

      results = store.read('sess1')
      expect(results.size).to eq(2)
      expect(results.map { |r| r['action'] }).to eq(%w[index create])
    end

    it 'returns empty array for unknown session' do
      expect(store.read('nonexistent')).to eq([])
    end

    it 'keeps formerly colliding session IDs isolated' do
      store.record('account/a', request_data.merge('action' => 'slash'))
      store.record('account?a', request_data.merge('action' => 'question'))

      expect(store.read('account/a').first['action']).to eq('slash')
      expect(store.read('account?a').first['action']).to eq('question')
    end
  end

  describe '#sessions' do
    it 'lists sessions with summaries' do
      store.record('sess1', request_data)
      store.record('sess1', request_data.merge('timestamp' => '2026-02-13T10:31:00Z'))

      summaries = store.sessions
      expect(summaries.size).to eq(1)
      expect(summaries[0]['session_id']).to eq('sess1')
      expect(summaries[0]['request_count']).to eq(2)
    end

    it 'respects limit' do
      3.times { |i| store.record("sess#{i}", request_data) }
      expect(store.sessions(limit: 2).size).to eq(2)
    end

    # #218 / B-105. Redis sets are unordered, so `smembers.first(limit)`
    # returned arbitrary members — a caller asking for recent sessions got a
    # random sample, while the FileStore twin genuinely sorts by mtime.
    describe 'ordering' do
      before do
        store.record('oldest', request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))
        store.record('newest', request_data.merge('timestamp' => '2026-02-13T12:00:00Z'))
        store.record('middle', request_data.merge('timestamp' => '2026-02-13T11:00:00Z'))
      end

      it 'returns sessions most-recent first' do
        expect(store.sessions.map { |s| s['session_id'] }).to eq(%w[newest middle oldest])
      end

      it 'truncates to the most recent when limited' do
        expect(store.sessions(limit: 2).map { |s| s['session_id'] }).to eq(%w[newest middle])
      end

      it 'orders by the last request, not the first' do
        store.record('oldest', request_data.merge('timestamp' => '2026-02-13T13:00:00Z'))

        expect(store.sessions.first['session_id']).to eq('oldest')
      end
    end
  end

  describe '#clear' do
    it 'removes a single session' do
      store.record('sess1', request_data)
      store.record('sess2', request_data)

      store.clear('sess1')

      expect(store.read('sess1')).to eq([])
      expect(store.read('sess2').size).to eq(1)
    end
  end

  describe '#clear_all' do
    it 'removes all sessions' do
      store.record('sess1', request_data)
      store.record('sess2', request_data)

      store.clear_all

      expect(store.read('sess1')).to eq([])
      expect(store.read('sess2')).to eq([])
      expect(store.sessions).to eq([])
    end
  end

  describe 'TTL support' do
    it 'applies the TTL to the session list' do
      allow(redis).to receive(:expire).and_call_original
      store_with_ttl = described_class.new(redis: redis, ttl: 3600)
      store_with_ttl.record('sess1', request_data)

      expect(redis).to have_received(:expire).with(kind_of(String), 3600)
    end
  end

  describe 'retention bounds' do
    it 'trims each session to the newest requests' do
      bounded = described_class.new(redis: redis, max_requests_per_session: 2)
      3.times { |i| bounded.record('sess1', request_data.merge('action' => "action_#{i}")) }

      expect(bounded.read('sess1').map { |entry| entry['action'] }).to eq(%w[action_1 action_2])
    end

    it 'bounds the active session index' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      3.times { |i| bounded.record("sess#{i}", request_data) }

      expect(bounded.sessions(limit: 10).size).to eq(2)
    end

    # Redis sets are unordered, so an eviction based on `smembers` order
    # evicts whatever the set happens to yield first — which, keyed on
    # insertion order here, is the OPPOSITE of chronological order below.
    # Eviction must instead go by last recorded activity.
    it 'evicts the oldest session by recorded activity, not by set/insertion order' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      bounded.record('newest', request_data.merge('timestamp' => '2026-02-13T12:00:00Z'))
      bounded.record('oldest', request_data.merge('timestamp' => '2026-02-13T09:00:00Z'))
      bounded.record('middle', request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))

      expect(bounded.read('oldest')).to eq([])
      expect(bounded.read('newest').size).to eq(1)
      expect(bounded.read('middle').size).to eq(1)
    end
  end

  describe 'dependency and serializer failures' do
    it 'raises an actionable error when the redis gem is absent' do
      script = <<~RUBY
        require 'woods'
        require 'woods/session_tracer/redis_store'
        Woods::SessionTracer::RedisStore.new(redis: Object.new)
      RUBY
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script
      )

      expect(status).not_to be_success
      expect(stderr).to include('redis gem is required')
    end

    it 'does not push a partial request when serialization fails' do
      cyclic = {}
      cyclic['self'] = cyclic
      allow(redis).to receive(:rpush).and_call_original

      expect { store.record('sess1', cyclic) }.to raise_error(JSON::NestingError)
      expect(redis).not_to have_received(:rpush)
    end
  end

  describe 'recency zset index (P4)' do
    # P4. prune_sessions read every candidate session's history to order
    # them, so once max_sessions was reached every record re-read all of
    # them. The index is now a recency ZSET scored by the request's own
    # timestamp; eviction order is unchanged and histories are never
    # re-read for eviction. The lrange count below fails on the pre-fix
    # shape, where prune called read() for every session.
    it 'evicts overflow without reading session histories' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      bounded.record('one', request_data)
      bounded.record('two', request_data)

      allow(redis).to receive(:lrange).and_call_original
      bounded.record('three', request_data)

      expect(redis).not_to have_received(:lrange)
      expect(bounded.sessions(limit: 10).map { |s| s['session_id'] }).to contain_exactly('two', 'three')
    end

    it 'scores the index by the request timestamp, so eviction matches last-request order' do
      bounded = described_class.new(redis: redis, max_sessions: 2)
      bounded.record('newest', request_data.merge('timestamp' => '2026-02-13T12:00:00Z'))
      bounded.record('oldest', request_data.merge('timestamp' => '2026-02-13T09:00:00Z'))
      bounded.record('middle', request_data.merge('timestamp' => '2026-02-13T10:00:00Z'))

      expect(bounded.read('oldest')).to eq([])
      expect(bounded.read('middle').size).to eq(1)
      expect(bounded.read('newest').size).to eq(1)
    end

    it 'falls back to write time when the request carries no parseable timestamp' do
      store.record('no_ts', { 'controller' => 'OrdersController' })

      expect(store.sessions.first['session_id']).to eq('no_ts')
    end

    it 'migrates a legacy set-based session index on first record' do
      redis.sadd(described_class::SESSIONS_KEY, 'legacy')
      store.record('fresh', request_data)

      expect(store.sessions.map { |s| s['session_id'] }).to eq(['fresh'])

      store.record('fresh', request_data.merge('action' => 'create'))
      expect(store.sessions.size).to eq(1)
    end

    # Review finding: the pre-fix migration was three separate commands
    # (SMEMBERS, DEL, re-ZADD) driven from Ruby, so two writers racing a
    # legacy index could interleave: writer A converted the key between
    # writer B's SMEMBERS and B's DEL, and B's DEL erased A's just-written
    # member. The hook below forces exactly that interleaving
    # deterministically: writer A's complete record runs inside writer B's
    # migration window (between B's SMEMBERS and B's DEL). On the fixed
    # shape there is no Ruby-side member read or DEL in the index path at
    # all (the script is atomic server-side), so the hook never fires and
    # writer A records sequentially instead.
    it 'keeps both writers indexed, with no orphaned list, when their migrations interleave' do
      redis.sadd(described_class::SESSIONS_KEY, 'legacy')
      store_a = described_class.new(redis: redis)
      store_b = described_class.new(redis: redis)

      del_calls = 0
      allow(redis).to receive(:del).and_wrap_original do |method, key|
        del_calls += 1
        store_a.record('one', request_data) if del_calls == 1
        method.call(key)
      end

      store_b.record('two', request_data)
      store_a.record('one', request_data) if del_calls.zero?

      indexed = redis.zrange(described_class::SESSIONS_KEY, 0, -1)
      expect(indexed).to contain_exactly('legacy', 'one', 'two')
      expect(store_b.read('two').size).to eq(1)
      expect(store_a.read('one').size).to eq(1)

      session_lists = redis.data.keys.select { |key| key.start_with?(described_class::KEY_PREFIX) }
      session_list_ids = session_lists.map do |key|
        encoded = key.delete_prefix(described_class::KEY_PREFIX)
        encoded.start_with?('b64.') ? Base64.urlsafe_decode64(encoded.delete_prefix('b64.')) : encoded
      end
      expect(session_list_ids).not_to be_empty
      expect(indexed).to include(*session_list_ids)
    end
  end
end
