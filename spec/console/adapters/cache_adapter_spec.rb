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
    #
    # `Rails.cache` is a class (module) method, so we mock the Rails module
    # itself via a plain double and swap it in with `stub_const`.
    # `instance_double('Rails')` would eventually verify against Rails-the-
    # class and fail once Rails loads earlier in a random-order run.
    let(:rails_double) { double('Rails') }

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
      hide_const('Rails')
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
      hide_const('SolidCache')
      expect(described_class.detect).to eq(:unknown)
    end

    it 'returns :unknown when Rails is not defined and SolidCache is not defined' do
      hide_const('Rails')
      hide_const('SolidCache')
      expect(described_class.detect).to eq(:unknown)
    end

    it 'returns :unknown for an unrecognised cache class even if SolidCache is absent' do
      custom_store = Class.new do
        def self.name = 'MyApp::Cache::FancyStore'
      end
      with_rails_cache(custom_store.new)
      hide_const('SolidCache')
      expect(described_class.detect).to eq(:unknown)
    end

    it 'returns :unknown for an anonymous cache class (nil .name)' do
      anonymous_store = Class.new # .name is nil
      with_rails_cache(anonymous_store.new)
      hide_const('SolidCache')
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

    # Pins current behaviour: Hash#compact drops nil, not empty strings. An
    # empty-string namespace is forwarded verbatim. If the contract changes
    # to treat '' as "no namespace", swap this to `.to eq({})`.
    it 'forwards an empty-string namespace verbatim' do
      expect(described_class.stats(namespace: '')[:params]).to eq(namespace: '')
    end
  end

  describe '.info' do
    it 'returns a bridge request for cache info' do
      expect(described_class.info).to eq(tool: 'cache_info', params: {})
    end
  end
end
