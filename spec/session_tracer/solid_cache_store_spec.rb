# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'woods/session_tracer/solid_cache_store'

# Minimal in-memory cache mock compatible with ActiveSupport::Cache::Store interface.
# Implements read/write/delete/exist? used by SolidCacheStore.
class MockCache
  attr_accessor :before_write

  def initialize
    @data = {}
    @expires = {}
    @mutex = Mutex.new
  end

  def read(key)
    @mutex.synchronize do
      expire!(key)
      @data[key]
    end
  end

  # rubocop:disable Naming/PredicateMethod
  def write(key, value, **options)
    @before_write&.call(key, value)
    @mutex.synchronize do
      expire!(key)
      @data[key] = value
      @expires[key] = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options[:expires_in] if options[:expires_in]
      true
    end
  end

  def increment(key, amount = 1, options = nil)
    options ||= {}
    @mutex.synchronize do
      expire!(key)
      @data[key] = @data.fetch(key, 0).to_i + amount
      @expires[key] ||= Process.clock_gettime(Process::CLOCK_MONOTONIC) + options[:expires_in] if options[:expires_in]
      @data[key]
    end
  end

  def keys
    @mutex.synchronize { @data.keys.dup }
  end

  def delete(key)
    @mutex.synchronize do
      @expires.delete(key)
      @data.delete(key)
    end
    true
  end
  # rubocop:enable Naming/PredicateMethod

  def exist?(key)
    !read(key).nil?
  end

  private

  def expire!(key)
    return unless @expires[key] && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @expires[key]

    @expires.delete(key)
    @data.delete(key)
  end
end

RSpec.describe Woods::SessionTracer::SolidCacheStore do
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

    it 'keeps formerly colliding session IDs isolated' do
      store.record('account/a', request_data.merge('action' => 'slash'))
      store.record('account?a', request_data.merge('action' => 'question'))

      expect(store.read('account/a').first['action']).to eq('slash')
      expect(store.read('account?a').first['action']).to eq('question')
    end

    it 'does not lose concurrent updates to one session' do
      threads = 20.times.map do |i|
        Thread.new { store.record('sess1', request_data.merge('action' => "action_#{i}")) }
      end
      threads.each(&:join)

      expect(store.read('sess1').size).to eq(20)
    end

    it 'coordinates concurrent updates across store instances sharing a backend' do
      other = described_class.new(cache: cache)
      threads = 20.times.map do |i|
        target = i.even? ? store : other
        Thread.new { target.record('sess1', request_data.merge('action' => "action_#{i}")) }
      end
      threads.each(&:join)

      expect(store.read('sess1').size).to eq(20)
      expect(store.sessions.map { |entry| entry['session_id'] }).to eq(['sess1'])
    end
    it 'keeps both committed records when two instances interleave after sequence allocation' do
      first_slot_started = Queue.new
      release_first_slot = Queue.new
      cache.before_write = lambda do |key, value|
        next unless key.end_with?(':record:1') && JSON.parse(value)['sequence'] == 1

        first_slot_started << true
        release_first_slot.pop
      end
      other = described_class.new(cache: cache)
      first = Thread.new { store.record('sess1', request_data.merge('action' => 'first')) }
      first_slot_started.pop
      second = Thread.new { other.record('sess1', request_data.merge('action' => 'second')) }
      second.join
      release_first_slot << true
      first.join

      expect(store.read('sess1').map { |entry| entry['action'] }).to eq(%w[first second])
    end

    it 'does not let a delayed older writer overwrite a wrapped slot' do
      bounded = described_class.new(cache: cache, max_requests_per_session: 1)
      other = described_class.new(cache: cache, max_requests_per_session: 1)
      first_slot_started = Queue.new
      release_first_slot = Queue.new
      cache.before_write = lambda do |key, value|
        next unless key.end_with?(':record:1') && JSON.parse(value)['sequence'] == 1

        first_slot_started << true
        release_first_slot.pop
      end
      first = Thread.new { bounded.record('sess1', request_data.merge('action' => 'first')) }
      first_slot_started.pop
      other.record('sess1', request_data.merge('action' => 'second'))
      release_first_slot << true
      first.join

      expect(bounded.read('sess1').map { |entry| entry['action'] }).to eq(['second'])
      expect(cache.keys.grep(/:record:/).size).to eq(1)
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
    it 'expires sequence, record, and index keys' do
      allow(cache).to receive(:write).and_call_original
      allow(cache).to receive(:increment).and_call_original
      store_with_expiry = described_class.new(cache: cache, expires_in: 3600)
      store_with_expiry.record('sess1', request_data)

      expect(cache).to have_received(:write).with(kind_of(String), kind_of(String), expires_in: 3600).twice
      expect(cache).to have_received(:increment).with(kind_of(String), 1, expires_in: 3600).twice
    end
  end

  describe 'retention bounds' do
    it 'keeps only the newest requests per session' do
      bounded = described_class.new(cache: cache, max_requests_per_session: 2)
      3.times { |i| bounded.record('sess1', request_data.merge('action' => "action_#{i}")) }

      expect(bounded.read('sess1').map { |entry| entry['action'] }).to eq(%w[action_1 action_2])
    end

    it 'bounds the session index' do
      bounded = described_class.new(cache: cache, max_sessions: 2)
      3.times { |i| bounded.record("sess#{i}", request_data) }

      expect(bounded.sessions(limit: 10).size).to eq(2)
    end
    it 'wraps record and global index slots without growing cache keys' do
      bounded = described_class.new(cache: cache, max_sessions: 2, max_requests_per_session: 2)
      12.times { |i| bounded.record("sess#{i % 3}", request_data.merge('action' => "action_#{i}")) }

      expect(cache.keys.grep(/:record:/).size).to be <= 6
      expect(cache.keys.grep(/session_index:slot/).size).to be <= 4
      expect(bounded.read('sess2').map { |entry| entry['action'] }).to eq(%w[action_8 action_11])
      expect(bounded.sessions(limit: 10).map { |entry| entry['session_id'] }.uniq.size).to be <= 2
    end

    it 'tolerates a crash after sequence allocation as a readable gap' do
      failed = false
      cache.before_write = lambda do |key, _value|
        next unless key.include?(':record:') && !failed

        failed = true
        raise IOError, 'simulated crash'
      end

      expect { store.record('sess1', request_data.merge('action' => 'lost')) }.to raise_error(IOError)
      cache.before_write = nil
      store.record('sess1', request_data.merge('action' => 'committed'))

      expect(store.read('sess1').map { |entry| entry['action'] }).to eq(['committed'])
    end

    it 'does not mutate the cache when serialization fails' do
      cyclic = {}
      cyclic['self'] = cyclic

      expect { store.record('sess1', cyclic) }.to raise_error(JSON::NestingError)
      expect(store.read('sess1')).to eq([])
    end
  end

  describe 'dependency absence' do
    it 'works with an injected compatible cache without loading solid_cache' do
      script = <<~RUBY
        require 'woods'
        require 'woods/session_tracer/solid_cache_store'
        cache = Class.new do
          def initialize = (@data = {})
          def read(key) = @data[key]
          def write(key, value, **) = (@data[key] = value)
          def increment(key, amount = 1, **) = (@data[key] = @data.fetch(key, 0).to_i + amount)
          def delete(key) = @data.delete(key)
          def exist?(key) = @data.key?(key)
        end.new
        store = Woods::SessionTracer::SolidCacheStore.new(cache: cache)
        store.record('session', { 'timestamp' => '2026-01-01T00:00:00Z' })
        abort 'solid_cache unexpectedly loaded' if defined?(SolidCache)
        print store.read('session').length
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script
      )

      expect(status).to be_success, stderr
      expect(stdout).to eq('1')
    end
  end

  describe 'atomic increment requirement' do
    it 'fails clearly when the backend cannot atomically increment' do
      unsupported = Class.new do
        def read(*) = nil
        def write(*) = true
        def delete(*) = true
      end.new

      expect { described_class.new(cache: unsupported) }
        .to raise_error(ArgumentError, /atomic #increment/)
    end
  end
end
