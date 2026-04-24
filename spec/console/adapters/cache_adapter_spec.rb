# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'active_support/cache'
require 'active_support/cache/memory_store'
require 'active_support/cache/file_store'
require 'woods/console/adapters/cache_adapter'

RSpec.describe Woods::Console::Adapters::CacheAdapter do
  describe '.detect' do
    # Use real ActiveSupport cache stores where possible so the detection
    # logic exercises actual Ruby class-name resolution rather than a double
    # that returns a preset string. RedisCacheStore is autoloaded lazily and
    # raises without the redis gem installed, so that one still uses a
    # name-returning stand-in — the detection contract is a substring match
    # on the class name, which we preserve.
    let(:rails_double) { instance_double('Rails') }

    def with_rails_cache(cache)
      allow(rails_double).to receive(:cache).and_return(cache)
      stub_const('Rails', rails_double)
    end

    it 'returns :memory for a real ActiveSupport::Cache::MemoryStore' do
      with_rails_cache(ActiveSupport::Cache::MemoryStore.new)
      expect(described_class.detect).to eq(:memory)
    end

    it 'returns :file for a real ActiveSupport::Cache::FileStore' do
      Dir.mktmpdir do |dir|
        with_rails_cache(ActiveSupport::Cache::FileStore.new(dir))
        expect(described_class.detect).to eq(:file)
      end
    end

    it 'returns :redis when the cache class name contains RedisCacheStore' do
      redis_stand_in = Class.new do
        def self.name = 'ActiveSupport::Cache::RedisCacheStore'
      end
      with_rails_cache(redis_stand_in.new)
      expect(described_class.detect).to eq(:redis)
    end

    it 'returns :solid_cache when SolidCache is defined and Rails is absent' do
      hide_const('Rails') if defined?(Rails)
      stub_const('SolidCache', Module.new)
      expect(described_class.detect).to eq(:solid_cache)
    end

    it 'falls back to :solid_cache when Rails.cache is nil but SolidCache is defined' do
      with_rails_cache(nil)
      stub_const('SolidCache', Module.new)
      expect(described_class.detect).to eq(:solid_cache)
    end

    it 'returns :unknown when Rails.cache is nil and SolidCache is not defined' do
      with_rails_cache(nil)
      hide_const('SolidCache') if defined?(SolidCache)
      expect(described_class.detect).to eq(:unknown)
    end

    it 'returns :unknown when Rails is not defined and SolidCache is not defined' do
      hide_const('Rails') if defined?(Rails)
      hide_const('SolidCache') if defined?(SolidCache)
      expect(described_class.detect).to eq(:unknown)
    end

    it 'returns :unknown for an unrecognised cache class even if SolidCache is absent' do
      custom_store = Class.new do
        def self.name = 'MyApp::Cache::FancyStore'
      end
      with_rails_cache(custom_store.new)
      hide_const('SolidCache') if defined?(SolidCache)
      expect(described_class.detect).to eq(:unknown)
    end

    it 'prefers Rails.cache class detection over the SolidCache fallback' do
      with_rails_cache(ActiveSupport::Cache::MemoryStore.new)
      stub_const('SolidCache', Module.new)
      expect(described_class.detect).to eq(:memory)
    end
  end

  describe '.stats' do
    it 'returns a bridge request for cache stats with an empty params hash when no namespace is given' do
      expect(described_class.stats).to eq(tool: 'cache_stats', params: {})
    end

    it 'compacts an explicit nil namespace out of params' do
      expect(described_class.stats(namespace: nil)).to eq(tool: 'cache_stats', params: {})
    end

    it 'includes the namespace when provided' do
      expect(described_class.stats(namespace: 'views')[:params]).to eq(namespace: 'views')
    end
  end

  describe '.info' do
    it 'returns a bridge request for cache info' do
      expect(described_class.info).to eq(tool: 'cache_info', params: {})
    end
  end
end
