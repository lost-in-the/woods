# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/adapters/cache_adapter'

RSpec.describe CodebaseIndex::Console::Adapters::CacheAdapter do
  describe '.detect' do
    it 'returns :redis when Redis cache store is configured' do
      stub_const('Rails', double(cache: double(class: double(name: 'ActiveSupport::Cache::RedisCacheStore'))))
      expect(described_class.detect).to eq(:redis)
    end

    it 'returns :solid_cache when SolidCache is defined' do
      hide_const('Rails') if defined?(Rails)
      stub_const('SolidCache', Module.new)
      expect(described_class.detect).to eq(:solid_cache)
    end

    it 'returns :memory when MemoryStore is configured' do
      stub_const('Rails', double(cache: double(class: double(name: 'ActiveSupport::Cache::MemoryStore'))))
      expect(described_class.detect).to eq(:memory)
    end

    it 'returns :file when FileStore is configured' do
      stub_const('Rails', double(cache: double(class: double(name: 'ActiveSupport::Cache::FileStore'))))
      expect(described_class.detect).to eq(:file)
    end

    it 'returns :unknown when no cache store is detected' do
      hide_const('Rails') if defined?(Rails)
      hide_const('SolidCache') if defined?(SolidCache)
      expect(described_class.detect).to eq(:unknown)
    end
  end

  describe '.stats' do
    it 'returns a bridge request for cache stats' do
      result = described_class.stats
      expect(result[:tool]).to eq('cache_stats')
      expect(result[:params]).to eq({})
    end

    it 'includes namespace when provided' do
      result = described_class.stats(namespace: 'views')
      expect(result[:params][:namespace]).to eq('views')
    end
  end

  describe '.info' do
    it 'returns a bridge request for cache info' do
      result = described_class.info
      expect(result[:tool]).to eq('cache_info')
      expect(result[:params]).to eq({})
    end
  end
end
