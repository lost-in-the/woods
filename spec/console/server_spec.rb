# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/server'

RSpec.describe Woods::Console::Server do
  let(:config) do
    { 'mode' => 'direct', 'command' => 'echo test' }
  end

  describe '.build' do
    it 'returns an MCP::Server instance' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'accepts nested console config' do
      nested_config = { 'console' => config }
      server = described_class.build(config: nested_config)
      expect(server).to be_a(MCP::Server)
    end

    it 'builds without redaction when no redacted_columns configured' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'builds with redaction when redacted_columns are configured' do
      config_with_redaction = config.merge('redacted_columns' => %w[ssn password])
      server = described_class.build(config: config_with_redaction)
      expect(server).to be_a(MCP::Server)
    end
  end

  describe 'tool registration' do
    it 'registers all tools on the server' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      expected_count = described_class::TIER1_TOOLS.size +
                       described_class::TIER2_TOOLS.size +
                       described_class::TIER3_TOOLS.size +
                       described_class::TIER4_TOOLS.size
      expect(tools.size).to eq(expected_count)
    end

    it 'registers all Tier 1 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER1_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 2 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER2_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 3 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER3_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end

    it 'registers all Tier 4 tool names' do
      server = described_class.build(config: config)
      tools = server.instance_variable_get(:@tools)

      described_class::TIER4_TOOLS.each do |tool|
        expect(tools).to have_key("console_#{tool}")
      end
    end
  end

  describe 'redaction via SafeContext' do
    let(:conn_mgr) do
      instance_double(Woods::Console::ConnectionManager).tap do |m|
        allow(m).to receive(:send_request).and_return(
          'ok' => true,
          'result' => { 'name' => 'Alice', 'ssn' => '123-45-6789', 'email' => 'alice@example.com' }
        )
      end
    end

    before do
      allow(Woods::Console::ConnectionManager).to receive(:new).and_return(conn_mgr)
    end

    it 'builds successfully when no redacted_columns configured' do
      server = described_class.build(config: config)
      expect(server).to be_a(MCP::Server)
    end

    it 'applies SafeContext redaction to Hash results' do
      safe_ctx = Woods::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[ssn]
      )
      result = { 'name' => 'Alice', 'ssn' => '123-45-6789', 'email' => 'alice@example.com' }
      redacted = safe_ctx.redact(result)
      expect(redacted['ssn']).to eq('[REDACTED]')
      expect(redacted['name']).to eq('Alice')
      expect(redacted['email']).to eq('alice@example.com')
    end

    it 'applies SafeContext redaction to Array of Hashes' do
      safe_ctx = Woods::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[password]
      )
      result = [
        { 'id' => 1, 'password' => 'secret1' },
        { 'id' => 2, 'password' => 'secret2' }
      ]
      redacted = described_class.send(:apply_redaction, result, safe_ctx)
      expect(redacted.map { |r| r['password'] }).to all(eq('[REDACTED]'))
      expect(redacted.map { |r| r['id'] }).to eq([1, 2])
    end

    it 'passes through non-Hash non-Array results unchanged' do
      safe_ctx = Woods::Console::SafeContext.new(
        connection: nil,
        redacted_columns: %w[ssn]
      )
      result = 42
      redacted = described_class.send(:apply_redaction, result, safe_ctx)
      expect(redacted).to eq(42)
    end

    describe 'shape-aware redaction' do
      let(:safe_ctx) do
        Woods::Console::SafeContext.new(
          connection: nil,
          redacted_columns: %w[crypted_password salt]
        )
      end

      it 'redacts records nested under `records` (sample / recent)' do
        result = {
          'records' => [
            { 'id' => 1, 'subdomain' => 'test', 'crypted_password' => 'abcdef' * 8, 'salt' => 'fedcba' * 8 },
            { 'id' => 2, 'subdomain' => 'other', 'crypted_password' => '0123' * 10, 'salt' => '4567' * 10 }
          ]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['records'].map { |r| r['crypted_password'] }).to all(eq('[REDACTED]'))
        expect(redacted['records'].map { |r| r['salt'] }).to all(eq('[REDACTED]'))
        expect(redacted['records'].map { |r| r['subdomain'] }).to eq(%w[test other])
      end

      it 'redacts a record nested under `record` (find)' do
        result = {
          'record' => { 'id' => 1, 'subdomain' => 'test', 'crypted_password' => 'deadbeef' * 5, 'salt' => 'cafe' * 10 }
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['record']['crypted_password']).to eq('[REDACTED]')
        expect(redacted['record']['salt']).to eq('[REDACTED]')
        expect(redacted['record']['subdomain']).to eq('test')
      end

      it 'handles `record` with a nil value (find with no match)' do
        result = { 'record' => nil }
        expect(described_class.send(:apply_redaction, result, safe_ctx)).to eq('record' => nil)
      end

      it 'redacts positional rows using `columns` header (sql / query)' do
        result = {
          'columns' => %w[id subdomain crypted_password salt],
          'rows' => [[1, 'test', 'abcdef' * 8, 'fedcba' * 8]],
          'count' => 1
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['rows']).to eq([[1, 'test', '[REDACTED]', '[REDACTED]']])
        expect(redacted['columns']).to eq(%w[id subdomain crypted_password salt])
        expect(redacted['count']).to eq(1)
      end

      it 'redacts positional multi-column values (pluck with multiple columns)' do
        result = {
          'columns' => %w[id subdomain crypted_password salt],
          'values' => [[1, 'test', 'abcdef' * 8, 'fedcba' * 8]]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['values']).to eq([[1, 'test', '[REDACTED]', '[REDACTED]']])
      end

      it 'redacts a flat values array (pluck with a single redacted column)' do
        result = {
          'columns' => %w[crypted_password],
          'values' => %w[aaaa bbbb cccc]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['values']).to eq(%w[[REDACTED] [REDACTED] [REDACTED]])
      end

      it 'leaves a flat values array untouched when the single column is not redacted' do
        result = {
          'columns' => %w[subdomain],
          'values' => %w[alpha beta gamma]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['values']).to eq(%w[alpha beta gamma])
      end

      it 'does not treat `console_schema` output as row data' do
        # schema returns {columns: {col_name => meta, ...}} — columns is a Hash,
        # not an Array, and there are no row/records keys, so redaction should
        # fall through to top-level key redaction (which is a no-op here).
        result = {
          'columns' => { 'id' => { 'type' => 'integer' }, 'crypted_password' => { 'type' => 'string' } }
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted).to eq(result)
      end

      it 'leaves rows untouched when no column matches the redacted list' do
        result = {
          'columns' => %w[id subdomain],
          'rows' => [[1, 'test'], [2, 'other']],
          'count' => 2
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['rows']).to eq([[1, 'test'], [2, 'other']])
      end
    end

    describe 'EAV (key-value) redaction' do
      # Models the real-world `authorizations` table where Stripe Connect
      # tokens live as rows like {key: "stripe_access_token", value: "sk_..."}.
      # Column-name redaction alone cannot protect these values — the column
      # is called `value`, which would over-redact every unrelated row.
      let(:safe_ctx) do
        Woods::Console::SafeContext.new(
          connection: nil,
          redacted_key_values: [
            { key_column: 'key', value_column: 'value',
              sensitive_keys: %w[stripe_access_token stripe_publishable_key stripe_user_id] }
          ]
        )
      end

      it 'redacts value under `record` when key is sensitive' do
        result = { 'record' => { 'id' => 1, 'key' => 'stripe_access_token', 'value' => 'sk_live_xyz' } }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['record']['value']).to eq('[REDACTED]')
        expect(redacted['record']['key']).to eq('stripe_access_token')
      end

      it 'leaves non-sensitive key rows intact under `record`' do
        result = { 'record' => { 'id' => 1, 'key' => 'timezone', 'value' => 'UTC' } }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['record']).to eq('id' => 1, 'key' => 'timezone', 'value' => 'UTC')
      end

      it 'redacts value across records (sample, recent)' do
        result = {
          'records' => [
            { 'id' => 1, 'key' => 'stripe_access_token', 'value' => 'sk_live_a' },
            { 'id' => 2, 'key' => 'timezone', 'value' => 'UTC' },
            { 'id' => 3, 'key' => 'stripe_publishable_key', 'value' => 'pk_live_b' }
          ]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        values = redacted['records'].map { |r| r['value'] }
        expect(values).to eq(['[REDACTED]', 'UTC', '[REDACTED]'])
      end

      it 'redacts positional rows (sql/query) when key column matches' do
        result = {
          'columns' => %w[id account_id key value],
          'rows' => [
            [1, 2, 'stripe_access_token',     'sk_live_xyz'],
            [2, 2, 'timezone',                'America/Chicago'],
            [3, 3, 'stripe_publishable_key',  'pk_live_abc']
          ],
          'count' => 3
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['rows'][0]).to eq([1, 2, 'stripe_access_token', '[REDACTED]'])
        expect(redacted['rows'][1]).to eq([2, 2, 'timezone', 'America/Chicago'])
        expect(redacted['rows'][2]).to eq([3, 3, 'stripe_publishable_key', '[REDACTED]'])
      end

      it 'redacts positional pluck values when key column matches' do
        result = {
          'columns' => %w[key value],
          'values' => [
            %w[stripe_access_token sk_live_xyz],
            %w[timezone UTC]
          ]
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['values']).to eq([
                                           ['stripe_access_token', '[REDACTED]'],
                                           ['timezone', 'UTC']
                                         ])
      end

      it 'no-ops when the header lacks both key and value columns' do
        # SELECT id FROM authorizations — no EAV cell to redact.
        result = { 'columns' => %w[id], 'rows' => [[1], [2]], 'count' => 2 }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['rows']).to eq([[1], [2]])
      end

      it 'combines column and key-value rules on the same response' do
        ctx = Woods::Console::SafeContext.new(
          connection: nil,
          redacted_columns: %w[crypted_password],
          redacted_key_values: [
            { key_column: 'key', value_column: 'value',
              sensitive_keys: %w[stripe_access_token] }
          ]
        )
        result = {
          'columns' => %w[id crypted_password key value],
          'rows' => [[1, 'hash1', 'stripe_access_token', 'sk_live'],
                     [2, 'hash2', 'timezone',            'UTC']]
        }
        redacted = described_class.send(:apply_redaction, result, ctx)
        expect(redacted['rows'][0]).to eq([1, '[REDACTED]', 'stripe_access_token', '[REDACTED]'])
        expect(redacted['rows'][1]).to eq([2, '[REDACTED]', 'timezone', 'UTC'])
      end
    end
  end
end
