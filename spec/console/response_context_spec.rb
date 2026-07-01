# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/response_context'
require 'woods/console/safe_context'
require 'woods/console/table_gate'
require 'woods/console/credential_scanner'

RSpec.describe Woods::Console::ResponseContext do
  describe '.build' do
    it 'returns NullResponseContext when every layer is absent' do
      ctx = described_class.build
      expect(ctx).to be(Woods::Console::NullResponseContext.instance)
    end

    it 'returns NullResponseContext when table_gate is inactive' do
      inactive_gate = Woods::Console::TableGate.new(blocked_tables: [], model_tables: {})
      expect(inactive_gate.active?).to be false

      ctx = described_class.build(table_gate: inactive_gate)
      expect(ctx).to be(Woods::Console::NullResponseContext.instance)
    end

    it 'returns a real ResponseContext when safe_ctx is present' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      ctx = described_class.build(safe_ctx: safe_ctx)

      expect(ctx).to be_a(described_class)
      expect(ctx.safe_ctx).to eq(safe_ctx)
    end

    it 'returns a real ResponseContext when table_gate is active' do
      gate = Woods::Console::TableGate.new(blocked_tables: %w[users], model_tables: {})
      ctx = described_class.build(table_gate: gate)

      expect(ctx).to be_a(described_class)
      expect(ctx.table_gate).to eq(gate)
    end

    it 'returns a real ResponseContext when credential_scanner is present' do
      scanner = Woods::Console::CredentialScanner.new
      ctx = described_class.build(credential_scanner: scanner)

      expect(ctx).to be_a(described_class)
      expect(ctx.credential_scanner).to eq(scanner)
    end
  end

  describe '#enforce!' do
    it 'raises when args reference a blocked SQL table' do
      gate = Woods::Console::TableGate.new(blocked_tables: %w[authorizations], model_tables: {})
      ctx = described_class.build(table_gate: gate)

      expect { ctx.enforce!(sql: 'SELECT * FROM authorizations') }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'raises when args reference a blocked model' do
      gate = Woods::Console::TableGate.new(
        blocked_tables: %w[authorizations], model_tables: { 'Authorization' => 'authorizations' }
      )
      ctx = described_class.build(table_gate: gate)

      expect { ctx.enforce!(model: 'Authorization') }
        .to raise_error(Woods::Console::TableGateError)
    end

    it 'is a no-op when no gate is configured' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      ctx = described_class.build(safe_ctx: safe_ctx)

      expect { ctx.enforce!(sql: 'SELECT * FROM authorizations') }.not_to raise_error
    end
  end

  describe '#redact' do
    it 'applies column redaction when safe_ctx is configured' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      ctx = described_class.build(safe_ctx: safe_ctx)

      redacted = ctx.redact('record' => { 'id' => 1, 'password' => 'secret' })
      expect(redacted['record']['password']).to eq('[REDACTED]')
    end

    it 'returns the value unchanged when safe_ctx is absent' do
      gate = Woods::Console::TableGate.new(blocked_tables: %w[users], model_tables: {})
      ctx = described_class.build(table_gate: gate)

      result = { 'record' => { 'id' => 1, 'password' => 'secret' } }
      expect(ctx.redact(result)).to eq(result)
    end
  end

  describe '#scan' do
    it 'returns [scanned_value, counts] when a scanner is configured' do
      scanner = Woods::Console::CredentialScanner.new
      ctx = described_class.build(credential_scanner: scanner)

      scanned, counts = ctx.scan('token: sk_live_abcdefghijklmnopqrstuvwx')
      expect(scanned).to include('[REDACTED')
      expect(counts.values.sum).to be > 0
    end

    it 'returns [value, {}] when no scanner is configured' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      ctx = described_class.build(safe_ctx: safe_ctx)

      scanned, counts = ctx.scan('token: sk_live_abcdefghijklmnopqrstuvwx')
      expect(scanned).to eq('token: sk_live_abcdefghijklmnopqrstuvwx')
      expect(counts).to eq({})
    end
  end

  describe '#present?' do
    it 'is true for a real context' do
      safe_ctx = Woods::Console::SafeContext.new(redacted_columns: %w[password])
      expect(described_class.build(safe_ctx: safe_ctx).present?).to be true
    end

    it 'is false for NullResponseContext' do
      expect(Woods::Console::NullResponseContext.instance.present?).to be false
    end
  end
end

RSpec.describe Woods::Console::NullResponseContext do
  subject(:ctx) { described_class.instance }

  it 'is a singleton' do
    expect(described_class.instance).to be(described_class.instance)
  end

  it 'exposes nil readers' do
    expect(ctx.safe_ctx).to be_nil
    expect(ctx.table_gate).to be_nil
    expect(ctx.credential_scanner).to be_nil
  end

  it 'treats enforce! as a no-op' do
    expect { ctx.enforce!(sql: 'anything', model: 'Anything') }.not_to raise_error
  end

  it 'returns the input unchanged from #redact' do
    payload = { 'record' => { 'id' => 1 } }
    expect(ctx.redact(payload)).to equal(payload)
  end

  it 'returns [value, {}] from #scan' do
    value = 'token: sk_live_xxx'
    expect(ctx.scan(value)).to eq([value, {}])
  end

  it 'is #present? false' do
    expect(ctx.present?).to be false
  end
end
