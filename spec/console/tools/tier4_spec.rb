# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/tools/tier4'
require 'codebase_index/console/sql_validator'
require 'codebase_index/console/audit_logger'
require 'codebase_index/console/confirmation'

RSpec.describe CodebaseIndex::Console::Tools::Tier4 do
  describe '.console_eval' do
    it 'builds an eval request with default timeout' do
      result = described_class.console_eval(code: 'User.count')
      expect(result[:tool]).to eq('eval')
      expect(result[:params][:code]).to eq('User.count')
      expect(result[:params][:timeout]).to eq(10)
    end

    it 'accepts a custom timeout' do
      result = described_class.console_eval(code: '1+1', timeout: 20)
      expect(result[:params][:timeout]).to eq(20)
    end

    it 'caps timeout at 30 seconds' do
      result = described_class.console_eval(code: '1+1', timeout: 60)
      expect(result[:params][:timeout]).to eq(30)
    end

    it 'enforces minimum timeout of 1 second' do
      result = described_class.console_eval(code: '1+1', timeout: 0)
      expect(result[:params][:timeout]).to eq(1)
    end
  end

  describe '.console_sql' do
    let(:validator) { CodebaseIndex::Console::SqlValidator.new }

    it 'builds a sql request for valid SELECT' do
      result = described_class.console_sql(sql: 'SELECT * FROM users', validator: validator)
      expect(result[:tool]).to eq('sql')
      expect(result[:params][:sql]).to eq('SELECT * FROM users')
    end

    it 'accepts WITH...SELECT (CTE)' do
      sql = 'WITH x AS (SELECT 1) SELECT * FROM x'
      result = described_class.console_sql(sql: sql, validator: validator)
      expect(result[:params][:sql]).to eq(sql)
    end

    it 'rejects INSERT via validator' do
      expect do
        described_class.console_sql(sql: 'INSERT INTO users VALUES (1)', validator: validator)
      end.to raise_error(CodebaseIndex::Console::SqlValidationError)
    end

    it 'rejects DELETE via validator' do
      expect do
        described_class.console_sql(sql: 'DELETE FROM users', validator: validator)
      end.to raise_error(CodebaseIndex::Console::SqlValidationError)
    end

    it 'accepts optional limit' do
      result = described_class.console_sql(sql: 'SELECT 1', validator: validator, limit: 100)
      expect(result[:params][:limit]).to eq(100)
    end

    it 'caps limit at 10000' do
      result = described_class.console_sql(sql: 'SELECT 1', validator: validator, limit: 50_000)
      expect(result[:params][:limit]).to eq(10_000)
    end
  end

  describe '.console_query' do
    it 'builds a query request with model and select' do
      result = described_class.console_query(model: 'User', select: %w[id name])
      expect(result[:tool]).to eq('query')
      expect(result[:params][:model]).to eq('User')
      expect(result[:params][:select]).to eq(%w[id name])
    end

    it 'includes joins when provided' do
      result = described_class.console_query(model: 'User', select: %w[id], joins: %w[posts])
      expect(result[:params][:joins]).to eq(%w[posts])
    end

    it 'includes group_by when provided' do
      result = described_class.console_query(
        model: 'User',
        select: %w[status],
        group_by: %w[status]
      )
      expect(result[:params][:group_by]).to eq(%w[status])
    end

    it 'includes having when provided' do
      result = described_class.console_query(
        model: 'Post',
        select: %w[user_id],
        group_by: %w[user_id],
        having: 'COUNT(*) > 5'
      )
      expect(result[:params][:having]).to eq('COUNT(*) > 5')
    end

    it 'includes order when provided' do
      result = described_class.console_query(model: 'User', select: %w[id], order: { id: :desc })
      expect(result[:params][:order]).to eq({ id: :desc })
    end

    it 'includes scope when provided' do
      result = described_class.console_query(model: 'User', select: %w[id], scope: { active: true })
      expect(result[:params][:scope]).to eq({ active: true })
    end

    it 'includes limit when provided' do
      result = described_class.console_query(model: 'User', select: %w[id], limit: 50)
      expect(result[:params][:limit]).to eq(50)
    end

    it 'caps limit at 10000' do
      result = described_class.console_query(model: 'User', select: %w[id], limit: 50_000)
      expect(result[:params][:limit]).to eq(10_000)
    end

    it 'compacts nil values from params' do
      result = described_class.console_query(model: 'User', select: %w[id])
      expect(result[:params].key?(:joins)).to be false
      expect(result[:params].key?(:group_by)).to be false
    end
  end
end
