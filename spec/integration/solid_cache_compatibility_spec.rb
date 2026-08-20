# frozen_string_literal: true

require 'spec_helper'

if ENV['WOODS_RUN_LIVE_BACKENDS']
  require 'rails'
  require 'active_record'
  require 'solid_cache'
  require 'woods/session_tracer/solid_cache_store'

  app_class = Class.new(Rails::Application) do
    config.eager_load = false
    config.logger = Logger.new(IO::NULL)
    config.secret_key_base = 'woods-solid-cache-compatibility'
  end
  Object.const_set(:WoodsSolidCacheCompatibilityApplication, app_class)
  WoodsSolidCacheCompatibilityApplication.initialize!

  class FirstIncrementBarrierCache < SolidCache::Store
    def initialize(**options)
      super(options)
      @arrivals = Hash.new(0)
      @mutex = Mutex.new
      @ready = ConditionVariable.new
    end

    def increment(key, amount = 1, **options)
      wait_for_competing_increment(key)
      super
    end

    private

    def wait_for_competing_increment(key)
      @mutex.synchronize do
        @arrivals[key] += 1
        if @arrivals[key] == 2
          @ready.broadcast
        else
          @ready.wait(@mutex) until @arrivals[key] == 2
        end
      end
    end
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
      ActiveRecord::Base.establish_connection(ENV.fetch('WOODS_PG_URL'))
      create_solid_cache_schema(ActiveRecord::Base.connection)
      example.run
    ensure
      ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
    end

    it 'shares atomic session sequences across actual Solid Cache stores' do
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
    it 'keeps both records when PostgreSQL interleaves first increments on absent counters' do
      cache = FirstIncrementBarrierCache.new(max_age: nil, max_entries: 10_000)
      first = Woods::SessionTracer::SolidCacheStore.new(cache: cache)
      second = Woods::SessionTracer::SolidCacheStore.new(cache: cache)
      writers = [first, second].each_with_index.map do |target, index|
        Thread.new do
          target.record('first-write', { 'timestamp' => '2026-08-20T12:00:00Z', 'action' => "action-#{index}" })
        end
      end
      writers.each(&:join)

      expect(first.read('first-write').map { |entry| entry.fetch('action') })
        .to contain_exactly('action-0', 'action-1')
    end
  end
end
