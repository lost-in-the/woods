# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/session_tracer/redis_store'

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
end
