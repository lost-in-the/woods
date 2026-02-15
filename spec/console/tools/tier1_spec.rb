# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/tools/tier1'

RSpec.describe CodebaseIndex::Console::Tools::Tier1 do
  describe '.console_count' do
    it 'builds a count request' do
      result = described_class.console_count(model: 'User')
      expect(result).to eq({ tool: 'count', params: { model: 'User' } })
    end

    it 'includes scope when provided' do
      result = described_class.console_count(model: 'User', scope: { active: true })
      expect(result[:params][:scope]).to eq({ active: true })
    end
  end

  describe '.console_sample' do
    it 'builds a sample request with defaults' do
      result = described_class.console_sample(model: 'Post')
      expect(result[:tool]).to eq('sample')
      expect(result[:params][:limit]).to eq(5)
    end

    it 'caps limit at 25' do
      result = described_class.console_sample(model: 'Post', limit: 100)
      expect(result[:params][:limit]).to eq(25)
    end

    it 'includes columns when provided' do
      result = described_class.console_sample(model: 'Post', columns: %w[id title])
      expect(result[:params][:columns]).to eq(%w[id title])
    end
  end

  describe '.console_find' do
    it 'builds a find request by id' do
      result = described_class.console_find(model: 'User', id: 42)
      expect(result[:tool]).to eq('find')
      expect(result[:params][:id]).to eq(42)
    end

    it 'builds a find request by unique column' do
      result = described_class.console_find(model: 'User', by: { email: 'a@b.com' })
      expect(result[:params][:by]).to eq({ email: 'a@b.com' })
    end

    it 'excludes nil params' do
      result = described_class.console_find(model: 'User')
      expect(result[:params]).to eq({ model: 'User' })
    end
  end

  describe '.console_pluck' do
    it 'builds a pluck request with defaults' do
      result = described_class.console_pluck(model: 'User', columns: %w[email])
      expect(result[:tool]).to eq('pluck')
      expect(result[:params][:limit]).to eq(100)
    end

    it 'caps limit at 1000' do
      result = described_class.console_pluck(model: 'User', columns: %w[email], limit: 5000)
      expect(result[:params][:limit]).to eq(1000)
    end

    it 'excludes false distinct by compact' do
      result = described_class.console_pluck(model: 'User', columns: %w[email], distinct: false)
      # false is not nil, so compact won't remove it
      expect(result[:params].key?(:distinct)).to be true
    end
  end

  describe '.console_aggregate' do
    it 'builds an aggregate request' do
      result = described_class.console_aggregate(model: 'Order', function: 'sum', column: 'total')
      expect(result[:tool]).to eq('aggregate')
      expect(result[:params][:function]).to eq('sum')
      expect(result[:params][:column]).to eq('total')
    end
  end

  describe '.console_association_count' do
    it 'builds an association_count request' do
      result = described_class.console_association_count(model: 'User', id: 1, association: 'posts')
      expect(result[:tool]).to eq('association_count')
      expect(result[:params][:association]).to eq('posts')
    end
  end

  describe '.console_schema' do
    it 'builds a schema request' do
      result = described_class.console_schema(model: 'User')
      expect(result[:tool]).to eq('schema')
      expect(result[:params][:include_indexes]).to be false
    end

    it 'includes indexes when requested' do
      result = described_class.console_schema(model: 'User', include_indexes: true)
      expect(result[:params][:include_indexes]).to be true
    end
  end

  describe '.console_recent' do
    it 'builds a recent request with defaults' do
      result = described_class.console_recent(model: 'Post')
      expect(result[:tool]).to eq('recent')
      expect(result[:params][:order_by]).to eq('created_at')
      expect(result[:params][:direction]).to eq('desc')
      expect(result[:params][:limit]).to eq(10)
    end

    it 'caps limit at 50' do
      result = described_class.console_recent(model: 'Post', limit: 200)
      expect(result[:params][:limit]).to eq(50)
    end
  end

  describe '.console_status' do
    it 'builds a status request' do
      result = described_class.console_status
      expect(result[:tool]).to eq('status')
      expect(result[:params]).to eq({})
    end
  end
end
