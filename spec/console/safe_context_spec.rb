# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/safe_context'

RSpec.describe Woods::Console::SafeContext do
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

    it 'sets statement timeout using PostgreSQL transaction-scoped syntax' do
      expect(connection).to receive(:execute).with("SET LOCAL statement_timeout = '3000ms'")
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

      it 'uses transaction-scoped statement_timeout with ms suffix' do
        ctx = described_class.new(connection: connection, timeout_ms: 7500)
        expect(connection).to receive(:execute).with("SET LOCAL statement_timeout = '7500ms'")
        ctx.execute { |_c| nil }
      end
    end
  end

  describe '#execute with pool:' do
    let(:pool_connection) do
      instance_double('PooledConnection').tap do |conn|
        allow(conn).to receive(:adapter_name).and_return('PostgreSQL')
        allow(conn).to receive(:execute)
        allow(conn).to receive(:transaction) do |&block|
          block.call
        rescue ActiveRecord::Rollback
          nil
        end
      end
    end

    let(:pool) do
      instance_double('ConnectionPool').tap do |p|
        allow(p).to receive(:with_connection).and_yield(pool_connection)
      end
    end

    it 'leases a connection from the pool for each execute' do
      ctx = described_class.new(pool: pool, timeout_ms: 1500)
      expect(pool).to receive(:with_connection).twice.and_yield(pool_connection)
      ctx.execute { |_c| nil }
      ctx.execute { |_c| nil }
    end

    it 'yields the leased connection into the block' do
      ctx = described_class.new(pool: pool)
      yielded = nil
      ctx.execute { |c| yielded = c }
      expect(yielded).to be(pool_connection)
    end

    it 'wraps the leased connection in a transaction with SET LOCAL timeout' do
      ctx = described_class.new(pool: pool, timeout_ms: 2500)
      expect(pool_connection).to receive(:execute)
        .with("SET LOCAL statement_timeout = '2500ms'")
      ctx.execute { |_c| nil }
    end

    it 'exposes the leased connection via the thread-local for nested handlers' do
      ctx = described_class.new(pool: pool)
      observed = nil
      ctx.execute do |_c|
        observed = Thread.current[:woods_console_leased_connection]
      end
      expect(observed).to be(pool_connection)
    end

    it 'clears the thread-local after execute returns' do
      ctx = described_class.new(pool: pool)
      ctx.execute { |_c| nil }
      expect(Thread.current[:woods_console_leased_connection]).to be_nil
    end

    it 'clears the thread-local even when the block raises' do
      ctx = described_class.new(pool: pool)
      expect { ctx.execute { |_c| raise 'boom' } }.to raise_error('boom')
      expect(Thread.current[:woods_console_leased_connection]).to be_nil
    end
  end

  describe '#execute' do
    it 'raises ArgumentError when neither connection: nor pool: was supplied' do
      ctx = described_class.new
      expect { ctx.execute { |_c| nil } }
        .to raise_error(ArgumentError, /connection.*pool/i)
    end

    it 'allows construction with neither connection: nor pool: for redaction-only use' do
      expect { described_class.new(redacted_columns: %w[ssn]) }.not_to raise_error
    end
  end

  describe 'multi-DB / shard pool coverage' do
    # Acceptance: rollback occurs on a non-default pool when a sharded model is
    # queried. SafeContext must NOT hold a captured connection ivar — it must
    # resolve the connection per #execute call so that whichever pool (default,
    # replica, or shard) is supplied, the rolled-back transaction covers that
    # pool's connection.
    #
    # The gap the fix closes: when connection: was stored as @connection at
    # init time, supplying a shard's pool to SafeContext and executing a block
    # that queries the shard opened the transaction on the *captured* connection
    # rather than on the connection leased from the shard pool — leaving shard
    # writes unprotected by the rollback.

    let(:shard_connection) do
      instance_double('ShardConnection').tap do |conn|
        allow(conn).to receive(:adapter_name).and_return('PostgreSQL')
        allow(conn).to receive(:execute)
        allow(conn).to receive(:transaction) do |&block|
          block.call
        rescue ActiveRecord::Rollback
          nil
        end
      end
    end

    let(:shard_pool) do
      instance_double('ShardPool').tap do |p|
        allow(p).to receive(:with_connection).and_yield(shard_connection)
      end
    end

    it 'opens a rolled-back transaction on the shard pool connection when pool: is a shard pool' do
      ctx = described_class.new(pool: shard_pool, timeout_ms: 1000)
      expect(shard_connection).to receive(:transaction)
      ctx.execute { |_c| nil }
    end

    it 'does NOT hold a @connection ivar — connection state lives on the pool or is nil' do
      ctx = described_class.new(pool: shard_pool)
      expect(ctx.instance_variables).not_to include(:@connection)
    end

    it 'rolls back on the shard pool connection (not the default pool) when shard pool is given' do
      rolled_back = false
      allow(shard_connection).to receive(:transaction) do |&block|
        block.call
        # If we reach here without Rollback being raised, rolled_back stays false
      rescue ActiveRecord::Rollback
        rolled_back = true
      end

      ctx = described_class.new(pool: shard_pool, timeout_ms: 500)
      ctx.execute { |_c| 'shard query here' }
      expect(rolled_back).to be true
    end

    it 'exposes the shard connection via the thread-local inside the execute block' do
      ctx = described_class.new(pool: shard_pool)
      observed_conn = nil
      ctx.execute { |_c| observed_conn = Thread.current[described_class::LEASED_CONNECTION_KEY] }
      expect(observed_conn).to be(shard_connection)
    end

    context 'connection: form (legacy / test fixtures)' do
      let(:fixed_conn) do
        instance_double('FixedConnection').tap do |conn|
          allow(conn).to receive(:adapter_name).and_return('PostgreSQL')
          allow(conn).to receive(:execute)
          allow(conn).to receive(:transaction) do |&block|
            block.call
          rescue ActiveRecord::Rollback
            nil
          end
        end
      end

      it 'does NOT hold a @connection ivar when constructed with connection:' do
        ctx = described_class.new(connection: fixed_conn)
        expect(ctx.instance_variables).not_to include(:@connection)
      end

      it 'still wraps the supplied connection in a rolled-back transaction per execute call' do
        rolled_back = false
        allow(fixed_conn).to receive(:transaction) do |&block|
          block.call
        rescue ActiveRecord::Rollback
          rolled_back = true
        end
        ctx = described_class.new(connection: fixed_conn)
        ctx.execute { |_c| 'query' }
        expect(rolled_back).to be true
      end

      it 'yields the supplied connection into the block' do
        ctx = described_class.new(connection: fixed_conn)
        yielded = nil
        ctx.execute { |c| yielded = c }
        expect(yielded).to be(fixed_conn)
      end

      it 'routes every execute call through pool.with_connection, never a captured ivar' do
        # Regression guard: before the fix, SafeContext stored @connection and
        # used it directly from #execute, bypassing any pool path. After the
        # fix, the supplied connection is wrapped in SingleConnectionPool so
        # every execute call must flow through pool.with_connection. This
        # spec would fail if someone re-introduced a captured @connection
        # that bypassed the pool — even if they tried to keep the ivar check
        # elsewhere happy.
        ctx = described_class.new(connection: fixed_conn)
        pool = ctx.instance_variable_get(:@pool)
        expect(pool).to respond_to(:with_connection)

        call_count = 0
        original = pool.method(:with_connection)
        allow(pool).to receive(:with_connection) do |&block|
          call_count += 1
          original.call(&block)
        end

        3.times { ctx.execute { |_c| 'noop' } }
        expect(call_count).to eq(3)
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

  describe '#redact with key-value (EAV) patterns' do
    let(:patterns) do
      [
        { key_column: 'key', value_column: 'value',
          sensitive_keys: %w[stripe_access_token stripe_publishable_key] }
      ]
    end

    subject(:ctx) do
      described_class.new(connection: connection, redacted_key_values: patterns)
    end

    it 'redacts value when key matches sensitive list' do
      input = { 'account_id' => 2, 'key' => 'stripe_access_token', 'value' => 'sk_live_abc' }
      result = ctx.redact(input)
      expect(result['value']).to eq('[REDACTED]')
      expect(result['key']).to eq('stripe_access_token')
      expect(result['account_id']).to eq(2)
    end

    it 'passes through rows whose key is not sensitive' do
      input = { 'account_id' => 2, 'key' => 'timezone', 'value' => 'America/Chicago' }
      expect(ctx.redact(input)).to eq(input)
    end

    it 'accepts string-keyed pattern hashes' do
      string_patterns = [
        { 'key_column' => 'name', 'value_column' => 'val',
          'sensitive_keys' => %w[oauth_token] }
      ]
      ctx = described_class.new(connection: connection, redacted_key_values: string_patterns)
      input = { 'name' => 'oauth_token', 'val' => 'secret123' }
      expect(ctx.redact(input)['val']).to eq('[REDACTED]')
    end

    it 'combines column and key-value redaction in the same pass' do
      ctx = described_class.new(
        connection: connection,
        redacted_columns: %w[password],
        redacted_key_values: patterns
      )
      input = { 'password' => 'pw', 'key' => 'stripe_access_token', 'value' => 'sk_live' }
      result = ctx.redact(input)
      expect(result['password']).to eq('[REDACTED]')
      expect(result['value']).to eq('[REDACTED]')
    end

    it 'coerces non-string key values before matching' do
      # Even if the key cell deserializes as a symbol or integer, the comparison
      # should still fire when to_s matches a sensitive entry.
      input = { 'key' => :stripe_access_token, 'value' => 'sk_live' }
      expect(ctx.redact(input)['value']).to eq('[REDACTED]')
    end

    it 'ignores patterns missing key_column, value_column, or sensitive_keys' do
      # Well-formed, underspecified patterns should be dropped silently rather
      # than raising — keeps misconfigured initializers from breaking the server.
      ctx = described_class.new(
        connection: connection,
        redacted_key_values: [
          { key_column: 'k', value_column: 'v' },                    # no sensitive_keys
          { key_column: 'k', sensitive_keys: %w[a] },                # no value_column
          { key_column: 'k', value_column: 'v', sensitive_keys: %w[x] }
        ]
      )
      expect(ctx.redacted_key_values.size).to eq(1)
    end
  end

  describe 'async-delivery stubbing during #execute (F-7)' do
    it 'swaps ActiveJob.queue_adapter to :test inside the block and restores after' do
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      fake_aj = Class.new do
        class << self
          attr_accessor :queue_adapter
        end
      end
      fake_aj.queue_adapter = :sidekiq
      stub_const('ActiveJob::Base', fake_aj)

      ctx = described_class.new(connection: connection)
      observed = nil
      ctx.execute { |_c| observed = fake_aj.queue_adapter }

      expect(observed).to eq(:test)
      expect(fake_aj.queue_adapter).to eq(:sidekiq)
    end

    it 'swaps ActionMailer delivery to :test and disables perform_deliveries inside the block' do
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      fake_am = Class.new do
        class << self
          attr_accessor :delivery_method, :perform_deliveries
        end
      end
      fake_am.delivery_method = :smtp
      fake_am.perform_deliveries = true
      stub_const('ActionMailer::Base', fake_am)

      ctx = described_class.new(connection: connection)
      observed_method = nil
      observed_perform = nil
      ctx.execute do |_c|
        observed_method = fake_am.delivery_method
        observed_perform = fake_am.perform_deliveries
      end

      expect(observed_method).to eq(:test)
      expect(observed_perform).to be false
      expect(fake_am.delivery_method).to eq(:smtp)
      expect(fake_am.perform_deliveries).to be true
    end

    it 'is a no-op when neither ActiveJob nor ActionMailer is loaded' do
      allow(connection).to receive(:adapter_name).and_return('PostgreSQL')
      ctx = described_class.new(connection: connection)
      expect { ctx.execute { |_c| 1 + 1 } }.not_to raise_error
    end
  end
end
