# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/redactor'

RSpec.describe Woods::Console::Redactor do
  # Normalize a single EAV pattern (symbol keys → string keys).
  def normalize_kv_pattern(pat)
    {
      'key_column' => pat[:key_column].to_s,
      'value_column' => pat[:value_column].to_s,
      'sensitive_keys' => Array(pat[:sensitive_keys]).map(&:to_s)
    }
  end

  # Apply EAV rules to an already column-redacted hash.
  def apply_kv_rules(hash, kvs)
    kvs.each do |rule|
      kc = rule['key_column']
      vc = rule['value_column']
      next unless hash.key?(kc) && hash.key?(vc)
      next unless rule['sensitive_keys'].include?(hash[kc].to_s)

      hash[vc] = '[REDACTED]'
    end
    hash
  end

  # Minimal stand-in for SafeContext. Exposes redacted_columns /
  # redacted_key_values and stubs #redact with the same logic SafeContext uses.
  def build_ctx(redacted_columns: [], redacted_key_values: [])
    cols = Array(redacted_columns).map(&:to_s)
    kvs  = Array(redacted_key_values).map { |p| normalize_kv_pattern(p) }

    double('SafeContext',
           redacted_columns: cols,
           redacted_key_values: kvs).tap do |ctx|
      allow(ctx).to receive(:redact) do |hash|
        str_hash = hash.transform_keys(&:to_s)
        column_redacted = str_hash.each_with_object({}) do |(k, v), out|
          out[k] = cols.include?(k) ? '[REDACTED]' : v
        end
        apply_kv_rules(column_redacted, kvs)
      end
    end
  end

  describe '.apply' do
    context 'with a plain Hash result (no envelope keys)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts the matched column and leaves others intact' do
        result = described_class.apply({ 'password' => 'hunter2', 'email' => 'x@y.z' }, ctx)
        expect(result['password']).to eq('[REDACTED]')
        expect(result['email']).to eq('x@y.z')
      end

      it 'converts symbol keys to string keys before redacting' do
        result = described_class.apply({ password: 'hunter2', email: 'x@y.z' }, ctx)
        expect(result['password']).to eq('[REDACTED]')
        expect(result['email']).to eq('x@y.z')
      end

      it 'leaves a non-redacted column unchanged' do
        ctx_clean = build_ctx(redacted_columns: ['secret'])
        result = described_class.apply({ 'email' => 'x@y.z', 'name' => 'Alice' }, ctx_clean)
        expect(result['email']).to eq('x@y.z')
        expect(result['name']).to eq('Alice')
      end

      it 'returns the original value when no columns are redacted' do
        ctx_empty = build_ctx
        result = described_class.apply({ 'password' => 'hunter2' }, ctx_empty)
        expect(result['password']).to eq('hunter2')
      end
    end

    context 'with an Array of Hashes' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts each Hash element in the array' do
        rows = [
          { 'password' => 'abc', 'id' => 1 },
          { 'password' => 'def', 'id' => 2 }
        ]
        result = described_class.apply(rows, ctx)
        expect(result.map { |r| r['password'] }).to eq(%w[[REDACTED] [REDACTED]])
        expect(result.map { |r| r['id'] }).to eq([1, 2])
      end

      it 'leaves non-Hash elements in an Array untouched' do
        result = described_class.apply([1, 'plain', nil], ctx)
        expect(result).to eq([1, 'plain', nil])
      end
    end

    context 'with a scalar result' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'returns the scalar unchanged' do
        expect(described_class.apply(42, ctx)).to eq(42)
        expect(described_class.apply(nil, ctx)).to be_nil
        expect(described_class.apply('string', ctx)).to eq('string')
      end
    end
  end

  describe '.apply — envelope shapes' do
    context '{record: Hash} shape (find)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts inside the record value' do
        result = described_class.apply(
          { 'record' => { 'password' => 'hunter2', 'email' => 'x@y.z' } },
          ctx
        )
        expect(result['record']['password']).to eq('[REDACTED]')
        expect(result['record']['email']).to eq('x@y.z')
      end

      it 'passes through a non-Hash record value unchanged' do
        result = described_class.apply({ 'record' => 'not_a_hash' }, ctx)
        expect(result['record']).to eq('not_a_hash')
      end
    end

    context '{records: [Hash]} shape (sample, recent)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts each record in the array' do
        result = described_class.apply(
          { 'records' => [
            { 'password' => 'abc', 'id' => 1 },
            { 'password' => 'xyz', 'id' => 2 }
          ] },
          ctx
        )
        expect(result['records'].map { |r| r['password'] }).to all(eq('[REDACTED]'))
      end

      it 'leaves non-Hash entries in records array untouched' do
        result = described_class.apply({ 'records' => [nil, 'bare'] }, ctx)
        expect(result['records']).to eq([nil, 'bare'])
      end
    end

    context '{columns:, rows:} shape (sql, query)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts positional cells where the column is in redacted_columns' do
        result = described_class.apply(
          { 'columns' => %w[id email password],
            'rows' => [[1, 'x@y.z', 'hunter2'], [2, 'a@b.c', 'secret']] },
          ctx
        )
        expect(result['rows'][0]).to eq([1, 'x@y.z', '[REDACTED]'])
        expect(result['rows'][1]).to eq([2, 'a@b.c', '[REDACTED]'])
      end

      it 'leaves rows untouched when no column names are in redacted_columns' do
        ctx_other = build_ctx(redacted_columns: ['ssn'])
        result = described_class.apply(
          { 'columns' => %w[id email], 'rows' => [[1, 'x@y.z']] },
          ctx_other
        )
        expect(result['rows'][0]).to eq([1, 'x@y.z'])
      end

      it 'passes envelope keys that are not data (e.g. total_count) through unchanged' do
        result = described_class.apply(
          { 'columns' => %w[id password], 'rows' => [[1, 'hunter2']], 'total_count' => 99 },
          ctx
        )
        expect(result['total_count']).to eq(99)
        expect(result['rows'][0]).to eq([1, '[REDACTED]'])
      end
    end

    context '{columns:, values:} shape (pluck)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts multi-column pluck rows (nested arrays)' do
        result = described_class.apply(
          { 'columns' => %w[id password],
            'values' => [[1, 'hunter2'], [2, 'secret']] },
          ctx
        )
        expect(result['values'][0]).to eq([1, '[REDACTED]'])
        expect(result['values'][1]).to eq([2, '[REDACTED]'])
      end

      it 'redacts a single-column pluck (flat scalar array)' do
        result = described_class.apply(
          { 'columns' => %w[password],
            'values' => %w[hunter2 secret] },
          ctx
        )
        expect(result['values']).to eq(%w[[REDACTED] [REDACTED]])
      end

      it 'does not redact scalars in a flat array when the column is not redacted' do
        ctx_other = build_ctx(redacted_columns: ['ssn'])
        result = described_class.apply(
          { 'columns' => %w[email],
            'values' => %w[x@y.z a@b.c] },
          ctx_other
        )
        expect(result['values']).to eq(%w[x@y.z a@b.c])
      end
    end

    context '{associations: Hash} shape (data_snapshot)' do
      let(:ctx) { build_ctx(redacted_columns: ['password']) }

      it 'redacts records in each association array' do
        result = described_class.apply(
          { 'record' => { 'id' => 1, 'password' => 'hunter2' },
            'associations' => {
              'orders' => [{ 'id' => 10, 'password' => 'p1' }],
              'comments' => [{ 'id' => 20, 'password' => 'p2' }]
            } },
          ctx
        )
        expect(result['associations']['orders'][0]['password']).to eq('[REDACTED]')
        expect(result['associations']['comments'][0]['password']).to eq('[REDACTED]')
      end

      it 'passes through a non-Hash associations value unchanged' do
        result = described_class.apply({ 'associations' => 'not_a_hash' }, ctx)
        expect(result['associations']).to eq('not_a_hash')
      end
    end
  end

  describe 'EAV (key-value) redaction' do
    let(:kv_pattern) do
      { key_column: 'key', value_column: 'value',
        sensitive_keys: %w[stripe_access_token oauth_token] }
    end
    let(:ctx) { build_ctx(redacted_key_values: [kv_pattern]) }

    context 'with {record: Hash} shape' do
      it 'redacts the value when the key cell matches a sensitive key' do
        result = described_class.apply(
          { 'record' => { 'key' => 'stripe_access_token', 'value' => 'sk_live_123' } },
          ctx
        )
        expect(result['record']['value']).to eq('[REDACTED]')
      end

      it 'leaves the value when the key cell does not match any sensitive key' do
        result = described_class.apply(
          { 'record' => { 'key' => 'theme', 'value' => 'dark' } },
          ctx
        )
        expect(result['record']['value']).to eq('dark')
      end
    end

    context 'with {columns:, rows:} shape' do
      it 'redacts the value column when the key cell matches a sensitive key' do
        result = described_class.apply(
          { 'columns' => %w[id key value],
            'rows' => [[1, 'oauth_token', 'tok_secret'], [2, 'theme', 'dark']] },
          ctx
        )
        expect(result['rows'][0]).to eq([1, 'oauth_token', '[REDACTED]'])
        expect(result['rows'][1]).to eq([2, 'theme', 'dark'])
      end

      it 'is a no-op when the columns header lacks the key or value column' do
        result = described_class.apply(
          { 'columns' => %w[id name],
            'rows' => [[1, 'alice']] },
          ctx
        )
        expect(result['rows'][0]).to eq([1, 'alice'])
      end

      it 'masks every value-named column when the value header is duplicated (CON-1 defense)' do
        # An alias can shadow the real value column ("id AS value"); index
        # resolution must not let the shadow steal the mask from the secret.
        result = described_class.apply(
          { 'columns' => %w[key value value],
            'rows' => [['stripe_access_token', 'sk_live_123', 7], ['theme', 'dark', 8]] },
          ctx
        )
        expect(result['rows'][0]).to eq(['stripe_access_token', '[REDACTED]', '[REDACTED]'])
        expect(result['rows'][1]).to eq(['theme', '[REDACTED]', '[REDACTED]'])
      end

      it 'masks every value-named column when the key header is duplicated (CON-1 defense)' do
        # A duplicated key header makes key attribution ambiguous, so no
        # per-row sensitive-key match can be trusted; mask unconditionally.
        result = described_class.apply(
          { 'columns' => %w[key value key],
            'rows' => [['stripe_access_token', 'sk_live_123', 7]] },
          ctx
        )
        expect(result['rows'][0]).to eq(['stripe_access_token', '[REDACTED]', 7])
      end
    end

    context 'with {records: [Hash]} shape' do
      it 'redacts sensitive EAV values across all records' do
        result = described_class.apply(
          { 'records' => [
            { 'key' => 'stripe_access_token', 'value' => 'sk_live_abc' },
            { 'key' => 'display_name',        'value' => 'Alice' }
          ] },
          ctx
        )
        expect(result['records'][0]['value']).to eq('[REDACTED]')
        expect(result['records'][1]['value']).to eq('Alice')
      end
    end
  end

  describe 'DATA_ENVELOPE_KEYS constant' do
    it 'includes record, records, rows, values, and associations' do
      expect(described_class::DATA_ENVELOPE_KEYS).to include('record', 'records', 'rows', 'values', 'associations')
    end

    it 'is frozen' do
      expect(described_class::DATA_ENVELOPE_KEYS).to be_frozen
    end
  end
end
