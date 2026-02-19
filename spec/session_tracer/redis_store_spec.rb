# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'codebase_index/session_tracer/redis_store'

# Minimal in-memory Redis mock for unit testing.
# Implements only the subset of Redis commands used by RedisStore.
class MockRedis
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

  # rubocop:disable Naming/PredicateMethod
  def expire(_key, _seconds)
    # No-op for tests (TTL not simulated)
    true
  end
  # rubocop:enable Naming/PredicateMethod

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

RSpec.describe CodebaseIndex::SessionTracer::RedisStore do
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
    it 'accepts ttl parameter' do
      store_with_ttl = described_class.new(redis: redis, ttl: 3600)
      expect { store_with_ttl.record('sess1', request_data) }.not_to raise_error
    end
  end
end
