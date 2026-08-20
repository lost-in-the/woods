# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'rbconfig'
require 'timeout'
require 'woods/session_tracer/solid_cache_store'

# Minimal in-memory cache mock compatible with ActiveSupport::Cache::Store interface.
# Implements read/write/delete/exist? used by SolidCacheStore.
class MockCache
  attr_accessor :after_increment, :after_read, :before_delete_attempt, :before_increment, :before_write,
                :before_write_if_absent
  attr_reader :read_count

  def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @data = {}
    @expires = {}
    @mutex = Mutex.new
    @read_count = 0
    @clock = clock
  end

  def read(key)
    value = @mutex.synchronize do
      @read_count += 1
      expire!(key)
      @data[key]
    end
    @after_read&.call(key, value)
    value
  end

  # rubocop:disable Naming/PredicateMethod
  def write(key, value, **options)
    @before_write&.call(key, value)
    @mutex.synchronize do
      expire!(key)
      return false if options[:unless_exist] && @data.key?(key)

      @data[key] = value
      @expires[key] = @clock.call + options[:expires_in] if options[:expires_in]
      true
    end
  end

  def write_if_absent(key, value, **options)
    @before_write_if_absent&.call(key, value)
    write(key, value, unless_exist: true, **options)
  end

  def increment(key, amount = 1, options = nil)
    options ||= {}
    @before_increment&.call(key, amount)
    value = @mutex.synchronize do
      expire!(key)
      @data[key] = @data.fetch(key, 0).to_i + amount
      @expires[key] ||= @clock.call + options[:expires_in] if options[:expires_in]
      @data[key]
    end
    @after_increment&.call(key, value)
    value
  end

  def keys
    @mutex.synchronize { @data.keys.dup }
  end

  def delete(key)
    @before_delete_attempt&.call(key)
    @mutex.synchronize do
      @expires.delete(key)
      @data.delete(key)
    end
    true
  end

  def delete_if_equal(key, expected)
    @before_delete_attempt&.call(key)
    @mutex.synchronize do
      expire!(key)
      return false unless @data[key] == expected

      @expires.delete(key)
      @data.delete(key)
      true
    end
  end
  # rubocop:enable Naming/PredicateMethod

  def exist?(key)
    !read(key).nil?
  end

  def reset_read_count
    @mutex.synchronize { @read_count = 0 }
  end

  private

  def expire!(key)
    return unless @expires[key] && @clock.call >= @expires[key]

    @expires.delete(key)
    @data.delete(key)
  end
end

# Reproduces Solid Cache 1.0's absent-row increment race while retaining the
# cache API's atomic unless_exist write contract.
class RacyInitialIncrementCache < MockCache
  def initialize
    super
    @barriers = Hash.new do |barriers, key|
      barriers[key] = { arrivals: 0, mutex: Mutex.new, ready: ConditionVariable.new }
    end
  end

  def increment(key, amount = 1, options = nil)
    return super unless read(key).nil?

    wait_for_competing_increment(key)
    write(key, amount, **(options || {}))
    amount
  end

  private

  def wait_for_competing_increment(key)
    barrier = @barriers[key]
    barrier[:mutex].synchronize do
      barrier[:arrivals] += 1
      if barrier[:arrivals] == 2
        barrier[:ready].broadcast
      else
        barrier[:ready].wait(barrier[:mutex]) until barrier[:arrivals] == 2
      end
    end
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

    it 'requires matching active and directory owners before reading records' do
      store.record('sess1', request_data)
      membership = JSON.parse(cache.read(store.send(:active_key, 'sess1')))
      cache.delete(store.send(:index_slot_key, membership.fetch('slot')))

      expect(store.read('sess1')).to eq([])
    end

    it 'returns empty when clear retires ownership while records are being collected' do
      store.record('sess1', request_data.merge('action' => 'first'))
      store.record('sess1', request_data.merge('action' => 'second'))
      cleared = false
      cache.after_read = lambda do |key, _value|
        next unless key.include?(':record:') && !cleared

        cleared = true
        store.clear('sess1')
      end

      result = Timeout.timeout(2) { store.read('sess1') }

      expect(result).to eq([])
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

    it 'initializes absent counters before concurrent first increments' do
      racy_cache = RacyInitialIncrementCache.new
      first = described_class.new(cache: racy_cache)
      second = described_class.new(cache: racy_cache)
      writers = [first, second].each_with_index.map do |target, index|
        Thread.new { target.record('new-session', request_data.merge('action' => "action_#{index}")) }
      end
      writers.each(&:join)

      expect(first.read('new-session').map { |entry| entry['action'] })
        .to contain_exactly('action_0', 'action_1')
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

    it 'scans past cleared recent sessions to find older active sessions' do
      bounded = described_class.new(cache: cache, max_sessions: 3)
      %w[older cleared-a cleared-b].each { |session_id| bounded.record(session_id, request_data) }
      bounded.clear('cleared-a')
      bounded.clear('cleared-b')

      expect(bounded.sessions(limit: 2).map { |entry| entry['session_id'] }).to eq(['older'])
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

    it 'tombstones a record that was allocated before clear but publishes afterward' do
      slot_started = Queue.new
      release_slot = Queue.new
      cache.before_write = lambda do |key, value|
        next unless key.end_with?(':record:1') && JSON.parse(value)['sequence'] == 1

        slot_started << true
        release_slot.pop
      end
      writer = Thread.new { store.record('sess1', request_data) }
      slot_started.pop

      store.clear('sess1')
      release_slot << true
      writer.join

      expect(store.read('sess1')).to eq([])
      expect(cache.keys.grep(/:record:/)).to be_empty
    end

    it 'does not delete a replacement active membership during a stale clear' do
      other = described_class.new(cache: cache, max_sessions: 1)
      bounded = described_class.new(cache: cache, max_sessions: 1)
      bounded.record('shared', request_data.merge('action' => 'old'))
      cache.before_delete_attempt = lambda do |key|
        next unless key.end_with?(':active')

        cache.before_delete_attempt = nil
        cache.delete(key)
        other.record('shared', request_data.merge('action' => 'replacement'))
      end

      bounded.clear('shared')

      expect(other.read('shared').map { |entry| entry['action'] }).to eq(['replacement'])
    end

    it 'keeps counters bounded when retirement repeatedly wins before increment' do
      bounded = described_class.new(cache: cache, max_sessions: 1)

      8.times do |index|
        bounded.record('shared', request_data.merge('action' => "admitted-#{index}"))
        increment_started = Queue.new
        release_increment = Queue.new
        cache.before_increment = lambda do |key, _amount|
          next if key == bounded.send(:index_sequence_key)

          increment_started << true
          release_increment.pop
        end
        writer = Thread.new { bounded.record('shared', request_data.merge('action' => "stale-#{index}")) }
        Timeout.timeout(2) { increment_started.pop }

        bounded.clear('shared')
        release_increment << true
        Timeout.timeout(2) { writer.join }
        cache.before_increment = nil
      end

      expect(cache.keys.grep(/:sequence\z/).size).to be <= 2
      expect(cache.keys.grep(/:record:/)).to be_empty
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

    it 'tombstones a record whose global reservation predates clear_all' do
      reservation_started = Queue.new
      release_reservation = Queue.new
      cache.after_increment = lambda do |key, value|
        next unless key == 'woods:session_index:sequence' && value == 1

        reservation_started << true
        release_reservation.pop
      end
      writer = Thread.new { store.record('new', request_data) }
      reservation_started.pop

      store.clear_all
      release_reservation << true
      writer.join

      expect(store.read('new')).to eq([])
      expect(store.sessions).to eq([])
      expect(cache.keys.grep(/:record:|session_index:slot:\d+\z/)).to be_empty
    end

    it 'conditionally removes corrupt directory slots' do
      cache.write(store.send(:index_slot_key, 0), '{broken')

      store.clear_all

      expect(cache.read(store.send(:index_slot_key, 0))).to be_nil
    end
  end

  describe 'expires_in support' do
    it 'slides observable session expiry after each successful record' do
      now = 0
      expiring_cache = MockCache.new(clock: -> { now })
      store_with_expiry = described_class.new(cache: expiring_cache, expires_in: 10)
      store_with_expiry.record('sess1', request_data.merge('action' => 'first'))

      now = 9
      store_with_expiry.record('sess1', request_data.merge('action' => 'second'))

      now = 11
      expect(store_with_expiry.read('sess1').map { |entry| entry['action'] }).to eq(['second'])

      now = 20
      expect(store_with_expiry.read('sess1')).to eq([])
      expect(expiring_cache.keys.grep(/woods:session:.*generation/)).to be_empty
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

    it 'reclaims invalid JSON directory slots before admitting a session' do
      bounded = described_class.new(cache: cache, max_sessions: 1)
      cache.write(bounded.send(:index_slot_key, 0), '{broken')

      bounded.record('recovered', request_data)

      expect(bounded.read('recovered')).to contain_exactly(request_data)
    end

    it 'reclaims scalar JSON directory slots before admitting a session' do
      bounded = described_class.new(cache: cache, max_sessions: 1)
      cache.write(bounded.send(:index_slot_key, 0), 'true')

      expect { bounded.record('recovered', request_data) }.not_to raise_error
      expect(bounded.read('recovered')).to contain_exactly(request_data)
    end

    it 'raises an actionable error after three directory claim collision waves' do
      bounded = described_class.new(cache: cache, max_sessions: 1)
      collision_waves = 0
      cache.before_write_if_absent = lambda do |key, _value|
        next unless key == bounded.send(:index_slot_key, 0)

        collision_waves += 1
        cache.write(key, "{collision-#{collision_waves}")
      end

      expect { bounded.record('contended', request_data) }
        .to raise_error(described_class::DirectoryContentionError, /3 attempts.*contended/)
      expect(collision_waves).to eq(3)
      expect(cache.keys.grep(/:record:/)).to be_empty
    end

    it 'evicts data and counters outside the active session bound' do
      bounded = described_class.new(cache: cache, max_sessions: 2, max_requests_per_session: 2)
      6.times { |i| bounded.record("sess#{i}", request_data) }

      expect(bounded.read('sess0')).to eq([])
      expect(bounded.read('sess5')).to contain_exactly(request_data)
      expect(cache.keys.grep(/:record:/).size).to be <= 4
      expect(cache.keys.grep(/woods:session:.*:sequence/).size).to be <= 2
    end

    it 'does not let a hot session consume active session discovery' do
      bounded = described_class.new(cache: cache, max_sessions: 2)
      bounded.record('cold', request_data)
      10.times { |i| bounded.record('hot', request_data.merge('action' => "action_#{i}")) }

      expect(bounded.sessions(limit: 10).map { |entry| entry['session_id'] })
        .to contain_exactly('cold', 'hot')
    end

    it 'keeps an old active session discoverable through cleared-session churn' do
      bounded = described_class.new(cache: cache, max_sessions: 2)
      bounded.record('keeper', request_data)
      8.times do |i|
        session_id = "cleared#{i}"
        bounded.record(session_id, request_data)
        bounded.clear(session_id)
      end
      bounded.record('newest', request_data)

      expect(bounded.sessions(limit: 10).map { |entry| entry['session_id'] })
        .to contain_exactly('keeper', 'newest')
    end

    it 'clears every retained session after churn' do
      bounded = described_class.new(cache: cache, max_sessions: 2)
      bounded.record('keeper', request_data)
      8.times do |i|
        session_id = "cleared#{i}"
        bounded.record(session_id, request_data)
        bounded.clear(session_id)
      end
      bounded.record('newest', request_data)

      bounded.clear_all

      expect(bounded.read('keeper')).to eq([])
      expect(bounded.read('newest')).to eq([])
      expect(cache.keys.grep(/:record:/)).to be_empty
    end

    it 'bounds admission, discovery, and clear_all work after indefinite churn' do
      bounded = described_class.new(cache: cache, max_sessions: 2)
      100.times do |i|
        session_id = "cleared#{i}"
        bounded.record(session_id, request_data)
        bounded.clear(session_id)
      end
      bounded.record('keeper', request_data)

      cache.reset_read_count
      bounded.record('newest', request_data)
      expect(cache.read_count).to be <= 24

      cache.reset_read_count
      expect(bounded.sessions(limit: 10).size).to eq(2)
      expect(cache.read_count).to be <= 24
      expect(cache.keys.size).to be <= 9

      cache.reset_read_count
      bounded.clear_all
      expect(cache.read_count).to be <= 24
    end

    it 'does not delete a replacement directory slot during stale retirement' do
      bounded = described_class.new(cache: cache, max_sessions: 1)
      replacement = described_class.new(cache: cache, max_sessions: 1)
      bounded.record('old', request_data)
      cache.before_delete_attempt = lambda do |key|
        next unless key == 'woods:session_index:slot:0'

        cache.before_delete_attempt = nil
        replacement.record('new', request_data)
      end

      bounded.clear('old')

      expect(replacement.sessions.map { |entry| entry['session_id'] }).to eq(['new'])
    end

    it 'bounds record and active-session keys without retaining evicted generations' do
      bounded = described_class.new(cache: cache, max_sessions: 2, max_requests_per_session: 2)
      12.times { |i| bounded.record("sess#{i % 3}", request_data.merge('action' => "action_#{i}")) }

      expect(cache.keys.grep(/:record:/).size).to be <= 4
      expect(cache.keys.grep(/session_index:slot:\d+\z/).size).to be <= 2
      expect(bounded.read('sess2').map { |entry| entry['action'] }).to eq(['action_11'])
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
          def write_if_absent(key, value)
            return false if @data.key?(key)

            @data[key] = value
            true
          end
          def increment(key, amount = 1, **) = (@data[key] = @data.fetch(key, 0).to_i + amount)
          def delete(key) = @data.delete(key)
          def delete_if_equal(key, expected) = (@data.delete(key) if @data[key] == expected)
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
      # Cache write/delete APIs return backend success rather than acting as predicates.
      # rubocop:disable Naming/PredicateMethod
      unsupported = Class.new do
        def read(*) = nil
        def write(*) = true
        def delete(*) = true
      end.new
      # rubocop:enable Naming/PredicateMethod

      expect { described_class.new(cache: unsupported) }
        .to raise_error(ArgumentError, /atomic #increment/)
    end

    it 'fails clearly when a generic backend cannot conditionally delete' do
      # Cache mutation APIs return backend success rather than acting as predicates.
      # rubocop:disable Naming/PredicateMethod
      unsupported = Class.new do
        def read(*) = nil
        def write(*) = true
        def write_if_absent(*) = true
        def increment(*) = 1
        def delete(*) = true
      end.new
      # rubocop:enable Naming/PredicateMethod

      expect { described_class.new(cache: unsupported) }
        .to raise_error(ArgumentError, /atomic #delete_if_equal/)
    end

    it 'fails clearly when a generic backend cannot atomically create keys' do
      # Cache mutation APIs return backend success rather than acting as predicates.
      # rubocop:disable Naming/PredicateMethod
      unsupported = Class.new do
        def read(*) = nil
        def write(*) = true
        def increment(*) = 1
        def delete(*) = true
        def delete_if_equal(*) = true
      end.new
      # rubocop:enable Naming/PredicateMethod

      expect { described_class.new(cache: unsupported) }
        .to raise_error(ArgumentError, /atomic #write_if_absent/)
    end
  end
end
