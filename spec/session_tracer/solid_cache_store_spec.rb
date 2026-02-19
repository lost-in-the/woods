# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'codebase_index/session_tracer/solid_cache_store'

# Minimal in-memory cache mock compatible with ActiveSupport::Cache::Store interface.
# Implements read/write/delete/exist? used by SolidCacheStore.
class MockCache
  def initialize
    @data = {}
  end

  def read(key)
    @data[key]
  end

  # rubocop:disable Naming/PredicateMethod
  def write(key, value, **_options)
    @data[key] = value
    true
  end

  def delete(key)
    @data.delete(key)
    true
  end
  # rubocop:enable Naming/PredicateMethod

  def exist?(key)
    @data.key?(key)
  end
end

RSpec.describe CodebaseIndex::SessionTracer::SolidCacheStore do
  let(:cache) { MockCache.new }
  let(:store) { described_class.new(cache: cache) }

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

    it 'returns empty when no sessions exist' do
      expect(store.sessions).to eq([])
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

  describe 'expires_in support' do
    it 'accepts expires_in parameter' do
      store_with_expiry = described_class.new(cache: cache, expires_in: 3600)
      expect { store_with_expiry.record('sess1', request_data) }.not_to raise_error
    end
  end
end
