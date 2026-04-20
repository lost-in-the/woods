# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/credential_scanner'

RSpec.describe Woods::Console::CredentialScanner do
  subject(:scanner) { described_class.new }

  describe '#scan' do
    context 'with Stripe secret keys' do
      it 'redacts sk_live_* tokens' do
        value, counts = scanner.scan('token is sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
        expect(value).to eq('token is [REDACTED]')
        expect(counts[:stripe_secret_key]).to eq(1)
      end

      it 'redacts sk_test_* tokens' do
        value, counts = scanner.scan('sk_test_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
        expect(value).to eq('[REDACTED]')
        expect(counts[:stripe_secret_key]).to eq(1)
      end

      it 'redacts rk_live_* restricted keys' do
        value, = scanner.scan('rk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
        expect(value).to eq('[REDACTED]')
      end

      it 'does not match short sk-prefixed strings that cannot be keys' do
        value, counts = scanner.scan('sk_live_short')
        expect(value).to eq('sk_live_short')
        expect(counts).to be_empty
      end
    end

    context 'with Stripe publishable keys' do
      it 'redacts pk_live_* tokens' do
        value, counts = scanner.scan('pk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
        expect(value).to eq('[REDACTED]')
        expect(counts[:stripe_publishable_key]).to eq(1)
      end
    end

    context 'with Stripe webhook secrets' do
      it 'redacts whsec_* values' do
        value, counts = scanner.scan('whsec_abcdefghijklmnopqrstuvwx')
        expect(value).to eq('[REDACTED]')
        expect(counts[:stripe_webhook_secret]).to eq(1)
      end
    end

    context 'with AWS access keys' do
      it 'redacts AKIA-prefixed access keys' do
        value, counts = scanner.scan('AKIAIOSFODNN7EXAMPLE')
        expect(value).to eq('[REDACTED]')
        expect(counts[:aws_access_key_id]).to eq(1)
      end

      it 'redacts ASIA-prefixed session keys' do
        value, = scanner.scan('ASIAIOSFODNN7EXAMPLE')
        expect(value).to eq('[REDACTED]')
      end

      it 'does not match lowercase or short AKIA-like strings' do
        value, counts = scanner.scan('AKIAshort')
        expect(value).to eq('AKIAshort')
        expect(counts).to be_empty
      end
    end

    context 'with GitHub tokens' do
      it 'redacts ghp_ personal access tokens' do
        value, counts = scanner.scan('ghp_abcdefghijklmnopqrstuvwxyz0123456789')
        expect(value).to eq('[REDACTED]')
        expect(counts[:github_token]).to eq(1)
      end

      it 'redacts gho_ OAuth tokens' do
        value, = scanner.scan('gho_abcdefghijklmnopqrstuvwxyz0123456789')
        expect(value).to eq('[REDACTED]')
      end
    end

    context 'with Google OAuth tokens' do
      it 'redacts ya29.* tokens' do
        value, counts = scanner.scan('ya29.a0AfH6SMBabcdefghijklmnopqrstuvwxyz')
        expect(value).to eq('[REDACTED]')
        expect(counts[:google_oauth_token]).to eq(1)
      end
    end

    context 'with JWT tokens' do
      it 'redacts three-part JWT tokens' do
        jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123'
        value, counts = scanner.scan(jwt)
        expect(value).to eq('[REDACTED]')
        expect(counts[:jwt_token]).to eq(1)
      end
    end

    context 'with PEM private key blocks' do
      it 'redacts the BEGIN marker' do
        pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIE...\n-----END RSA PRIVATE KEY-----"
        value, counts = scanner.scan(pem)
        expect(value).to include('[REDACTED]')
        expect(value).not_to include('BEGIN RSA PRIVATE KEY')
        expect(counts[:pem_private_key_block]).to eq(1)
      end
    end

    context 'with Slack tokens' do
      it 'redacts xoxb bot tokens' do
        value, counts = scanner.scan('xoxb-12345-abcdefghij-klmnopqrstuv')
        expect(value).to eq('[REDACTED]')
        expect(counts[:slack_token]).to eq(1)
      end
    end

    context 'when the string contains no credentials' do
      it 'returns the value unchanged' do
        value, counts = scanner.scan('Hello world, my account ID is acct_1Sx7cbE0QMvj9FH5')
        expect(value).to eq('Hello world, my account ID is acct_1Sx7cbE0QMvj9FH5')
        expect(counts).to be_empty
      end

      it 'leaves legitimate UUIDs alone' do
        value, counts = scanner.scan('550e8400-e29b-41d4-a716-446655440000')
        expect(value).to eq('550e8400-e29b-41d4-a716-446655440000')
        expect(counts).to be_empty
      end

      it 'leaves email addresses alone' do
        value, = scanner.scan('someone@example.com')
        expect(value).to eq('someone@example.com')
      end
    end

    context 'with multiple credentials in one string' do
      it 'redacts each and counts separately' do
        input = 'stripe sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE and ' \
                'aws AKIAIOSFODNN7EXAMPLE'
        value, counts = scanner.scan(input)
        expect(value).to include('[REDACTED]').twice
        expect(counts[:stripe_secret_key]).to eq(1)
        expect(counts[:aws_access_key_id]).to eq(1)
      end
    end

    context 'with Hash input' do
      it 'recursively scans string values' do
        input = { 'name' => 'Alice', 'token' => 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' }
        value, counts = scanner.scan(input)
        expect(value).to eq({ 'name' => 'Alice', 'token' => '[REDACTED]' })
        expect(counts[:stripe_secret_key]).to eq(1)
      end

      it 'preserves symbol keys' do
        input = { token: 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' }
        value, = scanner.scan(input)
        expect(value).to eq({ token: '[REDACTED]' })
      end
    end

    context 'with nested Hash/Array structures' do
      it 'scans deeply into nested arrays of hashes' do
        input = {
          'records' => [
            { 'key' => 'stripe_access_token',
              'value' => 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' },
            { 'key' => 'stripe_user_id', 'value' => 'acct_1Sx7cbE0QMvj9FH5' }
          ]
        }
        value, counts = scanner.scan(input)
        expect(value.dig('records', 0, 'value')).to eq('[REDACTED]')
        expect(value.dig('records', 1, 'value')).to eq('acct_1Sx7cbE0QMvj9FH5')
        expect(counts[:stripe_secret_key]).to eq(1)
      end

      it 'scans positional row arrays' do
        input = {
          'columns' => %w[id key value],
          'rows' => [
            [7, 'stripe_user_id', 'acct_1Sx7cbE0QMvj9FH5'],
            [8, 'stripe_access_token', 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE']
          ]
        }
        value, counts = scanner.scan(input)
        expect(value['rows'][1][2]).to eq('[REDACTED]')
        expect(value['rows'][0][2]).to eq('acct_1Sx7cbE0QMvj9FH5')
        expect(counts[:stripe_secret_key]).to eq(1)
      end
    end

    context 'with non-string scalar values' do
      it 'leaves integers, floats, booleans, and nil untouched' do
        input = { 'id' => 42, 'price' => 1.99, 'active' => true, 'deleted_at' => nil }
        value, counts = scanner.scan(input)
        expect(value).to eq(input)
        expect(counts).to be_empty
      end
    end
  end

  describe 'per-pattern disable' do
    it 'skips a disabled pattern' do
      scanner = described_class.new(disabled_patterns: %i[stripe_publishable_key])
      value, counts = scanner.scan(
        'pk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE and ' \
        'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE'
      )
      expect(value).to include('pk_live_')
      expect(value).to include('[REDACTED]')
      expect(counts[:stripe_publishable_key]).to be_nil.or eq(0)
      expect(counts[:stripe_secret_key]).to eq(1)
    end

    it 'accepts string pattern names' do
      scanner = described_class.new(disabled_patterns: %w[stripe_secret_key])
      value, = scanner.scan('sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
      expect(value).to include('sk_live_')
    end
  end

  describe '.patterns' do
    it 'returns the full pattern name list' do
      expect(described_class.patterns).to include(
        :stripe_secret_key, :stripe_publishable_key, :stripe_webhook_secret,
        :aws_access_key_id, :github_token, :google_oauth_token,
        :jwt_token, :pem_private_key_block, :slack_token
      )
    end
  end
end
