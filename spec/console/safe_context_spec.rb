# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index/console/safe_context'

RSpec.describe CodebaseIndex::Console::SafeContext do
  let(:connection) { instance_double('Connection') }

  before do
    # Simulate ActiveRecord transaction behavior: yields, catches Rollback
    allow(connection).to receive(:transaction) do |&block|
      block.call
    rescue ActiveRecord::Rollback
      nil
    end
    allow(connection).to receive(:execute)
  end

  describe '#execute' do
    subject(:ctx) { described_class.new(connection: connection, timeout_ms: 3000) }

    before do
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
    end

    it 'runs the block inside a transaction' do
      expect(connection).to receive(:transaction)
      ctx.execute { |_c| 'result' }
    end

    it 'sets statement timeout using PostgreSQL syntax' do
      expect(connection).to receive(:execute).with("SET statement_timeout = '3000ms'")
      ctx.execute { |_c| nil }
    end

    it 'returns the block result' do
      result = ctx.execute { |_c| { count: 42 } }
      expect(result).to eq({ count: 42 })
    end

    it 'silently handles timeout errors from unsupported adapters' do
      allow(connection).to receive(:execute).and_raise(StandardError, 'not supported')
      expect { ctx.execute { |_c| 'ok' } }.not_to raise_error
    end
  end

  describe '#set_timeout (adapter detection)' do
    context 'with a MySQL adapter' do
      let(:mysql_connection) do
        instance_double('MysqlConnection').tap do |conn|
          allow(conn).to receive(:adapter_name).and_return('Mysql2')
          allow(conn).to receive(:execute)
          allow(conn).to receive(:transaction) do |&block|
            block.call
          rescue ActiveRecord::Rollback
            nil
          end
        end
      end

      it 'uses max_execution_time syntax' do
        ctx = described_class.new(connection: mysql_connection, timeout_ms: 5000)
        expect(mysql_connection).to receive(:execute).with('SET max_execution_time = 5000')
        ctx.execute { |_c| nil }
      end

      it 'handles mysql adapter name case-insensitively' do
        allow(mysql_connection).to receive(:adapter_name).and_return('MySQL')
        ctx = described_class.new(connection: mysql_connection, timeout_ms: 2000)
        expect(mysql_connection).to receive(:execute).with('SET max_execution_time = 2000')
        ctx.execute { |_c| nil }
      end
    end

    context 'with a PostgreSQL adapter' do
      before do
        allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      end

      it 'uses statement_timeout syntax with ms suffix' do
        ctx = described_class.new(connection: connection, timeout_ms: 7500)
        expect(connection).to receive(:execute).with("SET statement_timeout = '7500ms'")
        ctx.execute { |_c| nil }
      end
    end
  end

  describe '#redact' do
    subject(:ctx) do
      described_class.new(connection: connection, redacted_columns: %w[ssn password])
    end

    it 'replaces redacted column values with [REDACTED]' do
      input = { 'name' => 'Alice', 'ssn' => '123-45-6789', 'email' => 'a@b.com' }
      result = ctx.redact(input)
      expect(result['ssn']).to eq('[REDACTED]')
      expect(result['name']).to eq('Alice')
      expect(result['email']).to eq('a@b.com')
    end

    it 'handles symbol keys' do
      input = { name: 'Bob', password: 'secret' }
      result = ctx.redact(input)
      expect(result['password']).to eq('[REDACTED]')
      expect(result['name']).to eq('Bob')
    end

    it 'returns hash unchanged when no redacted columns configured' do
      ctx_no_redaction = described_class.new(connection: connection, redacted_columns: [])
      input = { 'ssn' => '123' }
      expect(ctx_no_redaction.redact(input)).to eq(input)
    end
  end
end
