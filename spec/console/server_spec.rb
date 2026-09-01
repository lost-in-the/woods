# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/server'

RSpec.describe Woods::Console::Server do
  let(:config) do
    { 'mode' => 'direct', 'command' => 'echo test' }
  end

  describe '.build' do
    it 'fails closed because the JSON-lines bridge has no real executor' do
      expect { described_class.build(config: config) }
        .to raise_error(Woods::ConfigurationError, /bridge.*not supported/i)
    end
  end

  describe 'redaction via SafeContext' do
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

    describe 'Layer 3 envelope-key coverage (regression for unlisted keys)' do
      # Regression: apply_redaction previously only descended into a closed list
      # of envelope keys (record, records, rows, values). Any other key —
      # including `associations` returned by console_data_snapshot — was passed
      # through without redaction, creating a blind spot for custom-named
      # credential columns that also have no matching CredentialScanner shape.
      let(:safe_ctx) do
        Woods::Console::SafeContext.new(
          connection: nil,
          redacted_columns: %w[session_hmac internal_token_v2 webhook_secret_v3]
        )
      end

      it 'redacts sensitive columns inside `associations` (console_data_snapshot shape)' do
        # `data_snapshot` returns {record: {...}, associations: {name => [Hash, ...]}}
        # The `associations` key was NOT in DATA_ENVELOPE_KEYS, so nested hashes
        # were not walked and credentials leaked.
        result = {
          'record' => { 'id' => 1, 'name' => 'Order', 'session_hmac' => 'hmac-value-abc' },
          'associations' => {
            'tokens' => [
              { 'id' => 10, 'internal_token_v2' => 'tok_secret_xyz', 'kind' => 'api' },
              { 'id' => 11, 'internal_token_v2' => 'tok_secret_def', 'kind' => 'webhook' }
            ],
            'webhooks' => [
              { 'id' => 20, 'webhook_secret_v3' => 'whsec_abc123', 'url' => 'https://example.com' }
            ]
          }
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)

        # record key should still be redacted
        expect(redacted['record']['session_hmac']).to eq('[REDACTED]')
        expect(redacted['record']['name']).to eq('Order')

        # associations key must now also be redacted
        expect(redacted['associations']['tokens'][0]['internal_token_v2']).to eq('[REDACTED]')
        expect(redacted['associations']['tokens'][1]['internal_token_v2']).to eq('[REDACTED]')
        expect(redacted['associations']['webhooks'][0]['webhook_secret_v3']).to eq('[REDACTED]')

        # safe columns must pass through
        expect(redacted['associations']['tokens'][0]['kind']).to eq('api')
        expect(redacted['associations']['webhooks'][0]['url']).to eq('https://example.com')
      end

      it 'redacts across all association names in the associations map' do
        # Verifies that every association name's records are walked, not just the first.
        result = {
          'record' => { 'id' => 1, 'session_hmac' => 'hmac-root' },
          'associations' => {
            'tokens' => [{ 'id' => 10, 'internal_token_v2' => 'tok_secret_xyz' }],
            'webhooks' => [{ 'id' => 20, 'webhook_secret_v3' => 'whsec_abc123' }],
            'addresses' => [{ 'id' => 30, 'street' => '123 Main St' }]
          }
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        expect(redacted['associations']['tokens'][0]['internal_token_v2']).to eq('[REDACTED]')
        expect(redacted['associations']['webhooks'][0]['webhook_secret_v3']).to eq('[REDACTED]')
        expect(redacted['associations']['addresses'][0]['street']).to eq('123 Main St')
      end

      it 'does not redact the non-row `columns` metadata in console_schema output' do
        # Ensures recursive descent does not corrupt schema metadata payloads.
        result = {
          'columns' => { 'id' => { 'type' => 'integer' }, 'session_hmac' => { 'type' => 'string' } }
        }
        redacted = described_class.send(:apply_redaction, result, safe_ctx)
        # The *key name* "session_hmac" in schema metadata should not be touched —
        # only *values* of hash entries whose key is a redacted column should be redacted.
        expect(redacted['columns'].keys).to include('session_hmac')
        expect(redacted['columns']['session_hmac']).to eq('type' => 'string')
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
