# frozen_string_literal: true

require 'spec_helper'

if ENV['WOODS_RUN_LIVE_BACKENDS']
  require 'json'
  require 'open3'
  require 'rails'
  require 'active_record'
  require 'rbconfig'
  require 'solid_cache'
  require 'timeout'
  require 'tmpdir'
  require 'woods/session_tracer/solid_cache_store'

  app_class = Class.new(Rails::Application) do
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = 'woods-solid-cache-compatibility'
  end
  Object.const_set(:WoodsSolidCacheCompatibilityApplication, app_class)
  WoodsSolidCacheCompatibilityApplication.initialize!

  class MissingEntryBarrier
    attr_reader :absent_observations

    def initialize(key, parties: 2, timeout: 5)
      @key = key
      @parties = parties
      @timeout = timeout
      @absent_observations = 0
      @mutex = Mutex.new
      @ready = ConditionVariable.new
    end

    def observe(key, value)
      return unless key == @key && value.nil?

      @mutex.synchronize do
        @absent_observations += 1
        if @absent_observations == @parties
          @ready.broadcast
        else
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
          while @absent_observations < @parties
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Timeout::Error, 'missing-entry barrier timed out' unless remaining.positive?

            @ready.wait(@mutex, remaining)
          end
        end
      end
    end
  end

  module SolidCacheMissingEntryProbe
    def lock_and_write(key, &block)
      super do |value|
        Thread.current[:woods_missing_entry_barrier]&.observe(key, value)
        block.call(value)
      end
    end
  end

  unless SolidCache::Entry.singleton_class.ancestors.include?(SolidCacheMissingEntryProbe)
    SolidCache::Entry.singleton_class.prepend(SolidCacheMissingEntryProbe)
  end

  module SolidCacheEntryReadProbe
    def read(key)
      value = super
      Thread.current[:woods_entry_read_hook]&.call(key, value)
      value
    end
  end

  unless SolidCache::Entry.singleton_class.ancestors.include?(SolidCacheEntryReadProbe)
    SolidCache::Entry.singleton_class.prepend(SolidCacheEntryReadProbe)
  end

  # Run locally against PostgreSQL without the other live-lane services:
  # BUNDLE_GEMFILE=gemfiles/live_backends.gemfile WOODS_RUN_LIVE_BACKENDS=1 \
  #   WOODS_PG_URL=postgres://postgres:postgres@localhost:5432/woods_test \
  #   bundle exec rspec spec/integration/solid_cache_compatibility_spec.rb
  RSpec.describe 'Solid Cache session compatibility', :live_backends do
    def create_solid_cache_schema(connection)
      connection.create_table(:solid_cache_entries, force: true) do |table|
        table.binary :key, limit: 1024, null: false
        table.binary :value, limit: 536_870_912, null: false
        table.datetime :created_at, null: false
        table.integer :key_hash, limit: 8, null: false
        table.integer :byte_size, limit: 4, null: false
      end
      connection.add_index(:solid_cache_entries, :byte_size)
      connection.add_index(:solid_cache_entries, %i[key_hash byte_size])
      connection.add_index(:solid_cache_entries, :key_hash, unique: true)
      SolidCache::Entry.reset_column_information
    end

    around do |example|
      if example.metadata[:postgresql]
        ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_PG_URL'))
        create_solid_cache_schema(ActiveRecord::Base.connection)
        example.run
      else
        Dir.mktmpdir('woods-solid-cache') do |dir|
          ActiveRecord::Base.establish_connection(
            adapter: 'sqlite3', database: File.join(dir, 'cache.sqlite3'), pool: 8
          )
          create_solid_cache_schema(ActiveRecord::Base.connection)
          begin
            example.run
          ensure
            # Every SQLite handle must close BEFORE mktmpdir removes the
            # directory: an open pooled connection (or a late async Solid
            # Cache trim checking one out) can recreate the -wal/-shm
            # journals between remove_entry's unlink pass and its final
            # rmdir, failing cleanup with ENOTEMPTY. remove_connection also
            # drops the connection spec, so a straggler checkout raises
            # instead of reopening the database file.
            ActiveRecord::Base.remove_connection
          end
        end
      end
    ensure
      ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    end

    it 'shares atomic session sequences across actual Solid Cache stores', :postgresql do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000)
      first = Woods::SessionTracer::SolidCacheStore.new(cache: cache, max_requests_per_session: 32)
      second = Woods::SessionTracer::SolidCacheStore.new(
        cache: SolidCache::Store.new(max_age: nil, max_entries: 10_000), max_requests_per_session: 32
      )
      writers = 12.times.map do |index|
        Thread.new do
          target = index.even? ? first : second
          target.record('shared', { 'timestamp' => '2026-08-20T12:00:00Z', 'action' => "action-#{index}" })
        end
      end
      writers.each(&:join)

      expect(first.read('shared').map { |entry| entry.fetch('action') })
        .to contain_exactly(*12.times.map { |index| "action-#{index}" })
      expect(second.sessions.map { |entry| entry.fetch('session_id') }).to eq(['shared'])
      second.clear('shared')
      expect(first.read('shared')).to eq([])
    end
    it 'pre-creates counters before PostgreSQL increment transactions can observe absence', :postgresql do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000)
      direct_key = 'woods:probe:direct-absent-counter'
      direct_barrier = MissingEntryBarrier.new(direct_key)
      direct_writers = 2.times.map do
        Thread.new do
          Thread.current[:woods_missing_entry_barrier] = direct_barrier
          cache.increment(direct_key)
        ensure
          Thread.current[:woods_missing_entry_barrier] = nil
        end
      end
      direct_values = Timeout.timeout(10) { direct_writers.map(&:value) }

      expect(direct_barrier.absent_observations).to eq(2)
      expect(direct_values).to eq([1, 1])
      expect(cache.read(direct_key)).to eq(1)

      woods_key = 'woods:probe:initialized-counter'
      woods_barrier = MissingEntryBarrier.new(woods_key)
      stores = 2.times.map { Woods::SessionTracer::SolidCacheStore.new(cache: cache) }
      woods_writers = stores.map do |session_store|
        Thread.new do
          Thread.current[:woods_missing_entry_barrier] = woods_barrier
          session_store.send(:increment!, woods_key)
        ensure
          Thread.current[:woods_missing_entry_barrier] = nil
        end
      end
      woods_values = Timeout.timeout(10) { woods_writers.map(&:value) }

      expect(woods_barrier.absent_observations).to eq(0)
      expect(woods_values).to contain_exactly(1, 2)
      expect(cache.read(woods_key)).to eq(2)
    end

    it 'keeps ownership coherent inside a real Solid Cache local-cache scope' do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000)
      session_store = Woods::SessionTracer::SolidCacheStore.new(cache: cache)

      cache.with_local_cache do
        expect(session_store.read('locally-cached')).to eq([])
        session_store.record('locally-cached', { 'timestamp' => '2026-08-20T12:00:00Z' })

        expect(session_store.read('locally-cached'))
          .to contain_exactly('timestamp' => '2026-08-20T12:00:00Z')
      end
    end

    it 'reports whether a same-value conditional write actually inserted' do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000)
      coordination = Woods::SessionTracer::SolidCacheCoordination.new(cache)

      expect(coordination.write_if_absent('same-value', 0)).to be(true)
      expect(coordination.write_if_absent('same-value', 0)).to be(false)
      expect(coordination.read('same-value')).to eq(0)
    end

    def wait_for_entry_expiry(cache, name, timeout: 10)
      normalized = cache.send(:normalize_key, name, cache.send(:merged_options, nil))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        raw = SolidCache::Entry.read(normalized)
        entry = raw && cache.send(:deserialize_entry, raw, **cache.send(:merged_options, nil))
        return normalized if raw.nil? || entry.nil? || entry.expired?
        raise "entry #{name.inspect} never expired" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.005
      end
    end

    it 'does not delete a fresh replacement while cleaning up an expired entry' do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000)
      coordination = Woods::SessionTracer::SolidCacheCoordination.new(cache)
      coordination.write('contended', 'stale', expires_in: 0.01)
      normalized = wait_for_entry_expiry(cache, 'contended')

      replaced = false
      Thread.current[:woods_entry_read_hook] = lambda do |key, value|
        next unless key == normalized && value && !replaced

        replaced = true
        Thread.current[:woods_entry_read_hook] = nil
        coordination.write('contended', 'fresh')
      end
      begin
        expect(coordination.read('contended')).to be_nil
      ensure
        Thread.current[:woods_entry_read_hook] = nil
      end

      expect(replaced).to be(true)
      expect(coordination.read('contended')).to eq('fresh')
    end

    it 'keeps recording after a backend-level TTL expires every session key' do
      cache = SolidCache::Store.new(max_age: nil, max_entries: 10_000, expires_in: 0.5)
      session_store = Woods::SessionTracer::SolidCacheStore.new(cache: cache)
      session_store.record('ttl-session', { 'timestamp' => '2026-08-20T12:00:00Z', 'action' => 'before' })
      wait_for_entry_expiry(cache, session_store.send(:active_key, 'ttl-session'))

      expect(session_store.read('ttl-session')).to eq([])
      session_store.record('ttl-session', { 'timestamp' => '2026-08-20T12:00:05Z', 'action' => 'after' })

      expect(session_store.read('ttl-session').map { |entry| entry.fetch('action') }).to eq(['after'])
    end

    it 'routes every session key to its assigned Solid Cache shard' do
      script = <<~'RUBY'
        ENV['RAILS_ENV'] = 'test'

        require 'json'
        require 'rails'
        require 'active_record'
        require 'tmpdir'

        Dir.mktmpdir('woods-solid-cache-shards') do |dir|
          ActiveRecord::Base.configurations = {
            'test' => {
              'cache_one' => { 'adapter' => 'sqlite3', 'database' => File.join(dir, 'one.sqlite3') },
              'cache_two' => { 'adapter' => 'sqlite3', 'database' => File.join(dir, 'two.sqlite3') }
            }
          }
          connects_to = {
            shards: {
              one: { writing: :cache_one },
              two: { writing: :cache_two }
            }
          }
          require 'solid_cache'
          SolidCache::Engine.config.solid_cache.connects_to = connects_to

          app_class = Class.new(Rails::Application) do
            config.eager_load = false
            config.logger = Logger.new(IO::NULL)
            config.secret_key_base = 'woods-solid-cache-shards'
          end
          Object.const_set(:WoodsSolidCacheShardsApplication, app_class)
          WoodsSolidCacheShardsApplication.initialize!

          require 'woods/session_tracer/solid_cache_store'

          %i[one two].each do |shard|
            SolidCache::Record.connected_to(role: :writing, shard: shard) do
              connection = SolidCache::Record.connection
              connection.create_table(:solid_cache_entries, force: true) do |table|
                table.binary :key, limit: 1024, null: false
                table.binary :value, limit: 536_870_912, null: false
                table.datetime :created_at, null: false
                table.integer :key_hash, limit: 8, null: false
                table.integer :byte_size, limit: 4, null: false
              end
              connection.add_index(:solid_cache_entries, :key_hash, unique: true)
            end
          end
          SolidCache::Entry.reset_column_information

          cache = SolidCache::Store.new(shards: %i[one two], max_age: nil, max_entries: 10_000)
          store = Woods::SessionTracer::SolidCacheStore.new(cache: cache, max_sessions: 1)
          normalize = lambda do |key|
            cache.send(:normalize_key, key, cache.send(:merged_options, nil))
          end
          assigned_shard = lambda do |key|
            cache.connections.assign([normalize.call(key)]).keys.fetch(0)
          end

          fixed_shard = assigned_shard.call(store.send(:index_sequence_key))
          other_shard = (%i[one two] - [fixed_shard]).fetch(0)
          session_id = 1_000.times.map { |index| "sharded-#{index}" }.find do |candidate|
            assigned_shard.call(store.send(:active_key, candidate)) == other_shard
          end
          raise 'could not select a cross-shard session key' unless session_id

          record = { 'timestamp' => '2026-08-20T12:00:00Z', 'action' => 'routed' }
          store.record(session_id, record)
          raise 'session record was lost' unless store.read(session_id) == [record]

          active_key = store.send(:active_key, session_id)
          membership = JSON.parse(cache.read(active_key))
          keys = [
            store.send(:index_sequence_key),
            store.send(:index_slot_key, membership.fetch('slot')),
            store.send(:slot_sequence_key, membership.fetch('slot')),
            active_key,
            store.send(:record_key, membership.fetch('slot'), 1)
          ]
          placements = keys.to_h do |key|
            normalized_key = normalize.call(key)
            actual = %i[one two].select do |shard|
              SolidCache::Record.connected_to(role: :writing, shard: shard) do
                !SolidCache::Entry.read(normalized_key).nil?
              end
            end
            [key, [assigned_shard.call(key), actual]]
          end
          raise "misrouted keys: #{placements.inspect}" unless placements.values.all? do |expected, actual|
            actual == [expected]
          end
          raise "only one shard used: #{placements.inspect}" unless placements.values.map(&:first).uniq.size == 2

          print 'ok'
        ensure
          SolidCache::Record.connection_handler.clear_all_connections!
          # SQLite in WAL mode leaves -wal/-shm sidecars that clear_all_connections!
          # does not synchronously remove, so Dir.mktmpdir's own rmdir raced them
          # to Errno::ENOTEMPTY and failed the subprocess after its logic passed.
          # Empty the directory ourselves before mktmpdir cleans it up.
          Dir.glob(File.join(dir, '*')).each { |file| File.delete(file) }
        end
      RUBY
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, '-I', File.expand_path('../../lib', __dir__), '-e', script
      )

      expect(status).to be_success, stderr
      expect(stdout).to eq('ok')
    end
  end
end
