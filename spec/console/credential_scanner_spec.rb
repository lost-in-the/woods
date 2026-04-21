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

    context 'with GitHub fine-grained PATs' do
      it 'redacts github_pat_ tokens at the exact length' do
        pat = "github_pat_#{'A' * 82}"
        value, counts = scanner.scan(pat)
        expect(value).to eq('[REDACTED]')
        expect(counts[:github_fine_grained_pat]).to eq(1)
      end
    end

    context 'with SendGrid API keys' do
      it 'redacts SG.xxx.yyy two-part keys' do
        key = "SG.#{'a' * 22}.#{'b' * 43}"
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:sendgrid_api_key]).to eq(1)
      end

      it 'does not match short SG. prefixed strings' do
        value, counts = scanner.scan('SG.short.nope')
        expect(value).to eq('SG.short.nope')
        expect(counts).to be_empty
      end
    end

    context 'with Mailgun API keys' do
      it 'redacts key-<32 hex> tokens' do
        value, counts = scanner.scan("key-#{'a' * 32}")
        expect(value).to eq('[REDACTED]')
        expect(counts[:mailgun_api_key]).to eq(1)
      end

      it 'does not match key- followed by non-hex or short strings' do
        value, counts = scanner.scan('key-ABC')
        expect(value).to eq('key-ABC')
        expect(counts).to be_empty
      end
    end

    context 'with Anthropic API keys' do
      it 'redacts sk-ant-api prefixed keys' do
        key = "sk-ant-api03-#{'a' * 80}"
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:anthropic_api_key]).to eq(1)
      end

      it 'redacts sk-ant-admin prefixed keys' do
        key = "sk-ant-admin01-#{'b' * 80}"
        value, = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
      end

      it 'counts as anthropic not openai when both patterns could match' do
        key = "sk-ant-api03-#{'a' * 80}"
        _, counts = scanner.scan(key)
        expect(counts[:anthropic_api_key]).to eq(1)
        expect(counts[:openai_api_key]).to be_nil
      end
    end

    context 'with OpenAI API keys' do
      it 'redacts sk- prefixed keys with sufficient length' do
        key = "sk-#{'a' * 48}"
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:openai_api_key]).to eq(1)
      end

      it 'redacts sk-proj- project-scoped keys' do
        key = "sk-proj-#{'a' * 48}"
        value, = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
      end
    end

    context 'with Shopify access tokens' do
      it 'redacts shpat_ admin API tokens' do
        value, counts = scanner.scan("shpat_#{'a' * 32}")
        expect(value).to eq('[REDACTED]')
        expect(counts[:shopify_access_token]).to eq(1)
      end

      it 'redacts shpca_, shpss_, shppa_, shprt_, and shpua_ variants' do
        # shprt_ (refresh tokens) and shpua_ (user-access tokens) were missing
        # from the alternation before the Tier 1 hardening pass.
        %w[shpca_ shpss_ shppa_ shprt_ shpua_].each do |prefix|
          value, = scanner.scan("#{prefix}#{'a' * 32}")
          expect(value).to eq('[REDACTED]'), "Failed for prefix #{prefix}"
        end
      end
    end

    context 'with Stripe Connect account IDs' do
      it 'redacts acct_<16+ alnum> identifiers as PII' do
        value, counts = scanner.scan('acct_1Sx7cbE0QMvj9FH5')
        expect(value).to eq('[REDACTED]')
        expect(counts[:stripe_connect_account_id]).to eq(1)
      end

      it 'does not match short acct_ prefixed strings' do
        value, counts = scanner.scan('acct_short')
        expect(value).to eq('acct_short')
        expect(counts).to be_empty
      end
    end

    context 'with Klaviyo private API keys' do
      it 'redacts pk_<34 alnum> tokens' do
        value, counts = scanner.scan("pk_#{'a' * 34}")
        expect(value).to eq('[REDACTED]')
        expect(counts[:klaviyo_private_key]).to eq(1)
      end

      it 'counts a Stripe pk_live_* key as stripe_publishable_key, not klaviyo' do
        # Stripe's `_` after `live` interrupts Klaviyo's 34-alnum run; pattern
        # order also guarantees stripe_publishable_key consumes the match first.
        _, counts = scanner.scan('pk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE')
        expect(counts[:stripe_publishable_key]).to eq(1)
        expect(counts[:klaviyo_private_key]).to be_nil
      end
    end

    context 'with Salesforce access tokens' do
      it 'redacts 00D<15 alnum>!<base64 payload> session IDs' do
        token = "00D#{'a' * 12}!#{'A' * 90}"
        value, counts = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
        expect(counts[:salesforce_access_token]).to eq(1)
      end

      it 'does not match short 00D-prefixed strings' do
        value, counts = scanner.scan('00Dabcdefghijkl!short')
        expect(value).to eq('00Dabcdefghijkl!short')
        expect(counts).to be_empty
      end
    end

    context 'with LaunchDarkly keys' do
      it 'redacts sdk-<UUID> SDK keys' do
        key = 'sdk-12345678-1234-1234-1234-123456789012'
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:launchdarkly_sdk_key]).to eq(1)
      end

      it 'redacts mob-<UUID> mobile keys' do
        key = 'mob-deadbeef-cafe-1234-5678-abcdef012345'
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:launchdarkly_mobile_key]).to eq(1)
      end
    end

    context 'with HubSpot private app tokens' do
      it 'redacts pat-<region>-<UUID> tokens' do
        token = 'pat-na1-12345678-1234-1234-1234-123456789012'
        value, counts = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
        expect(counts[:hubspot_private_app_token]).to eq(1)
      end

      it 'redacts EU and AP region prefixes' do
        %w[eu1 eu2 ap1 na2].each do |region|
          token = "pat-#{region}-12345678-1234-1234-1234-123456789012"
          value, = scanner.scan(token)
          expect(value).to eq('[REDACTED]'), "Failed for region #{region}"
        end
      end
    end

    context 'with Brevo (Sendinblue) keys' do
      it 'redacts xkeysib-<64 hex>-<16 alnum> API keys' do
        key = "xkeysib-#{'a' * 64}-#{'b' * 16}"
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:brevo_api_key]).to eq(1)
      end

      it 'redacts xsmtpsib-<64 hex>-<16 alnum> SMTP keys' do
        key = "xsmtpsib-#{'a' * 64}-#{'b' * 16}"
        value, counts = scanner.scan(key)
        expect(value).to eq('[REDACTED]')
        expect(counts[:brevo_smtp_key]).to eq(1)
      end
    end

    context 'with Kit (ConvertKit) API keys' do
      it 'redacts kit_-prefixed tokens' do
        value, counts = scanner.scan("kit_#{'a' * 24}")
        expect(value).to eq('[REDACTED]')
        expect(counts[:kit_api_key]).to eq(1)
      end

      it 'does not match short kit_ prefixed strings' do
        value, counts = scanner.scan('kit_short')
        expect(value).to eq('kit_short')
        expect(counts).to be_empty
      end
    end

    context 'with Twilio identifiers' do
      it 'redacts AC<32 hex> account SIDs' do
        sid = "AC#{'a' * 32}"
        value, counts = scanner.scan(sid)
        expect(value).to eq('[REDACTED]')
        expect(counts[:twilio_account_sid]).to eq(1)
      end

      it 'redacts SK<32 hex> API key SIDs' do
        sid = "SK#{'b' * 32}"
        value, counts = scanner.scan(sid)
        expect(value).to eq('[REDACTED]')
        expect(counts[:twilio_api_key_sid]).to eq(1)
      end

      it 'redacts VA<32 hex> Verify service SIDs' do
        sid = "VA#{'c' * 32}"
        value, counts = scanner.scan(sid)
        expect(value).to eq('[REDACTED]')
        expect(counts[:twilio_verify_service_sid]).to eq(1)
      end
    end

    context 'with Square access tokens' do
      it 'redacts sq0csp- secrets' do
        token = "sq0csp-#{'a' * 43}"
        value, counts = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
        expect(counts[:square_access_token]).to eq(1)
      end

      it 'redacts sq0atp- access tokens' do
        token = "sq0atp-#{'a' * 22}"
        value, = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
      end
    end

    context 'with PayPal access tokens' do
      it 'redacts production access tokens' do
        token = 'access_token$production$abc123xyz456$a1b2c3d4e5f6'
        value, counts = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
        expect(counts[:paypal_access_token]).to eq(1)
      end

      it 'redacts sandbox access tokens' do
        token = 'access_token$sandbox$testclient$deadbeef123'
        value, = scanner.scan(token)
        expect(value).to eq('[REDACTED]')
      end
    end

    context 'when the string contains no credentials' do
      it 'returns the value unchanged' do
        value, counts = scanner.scan('Hello world, just plain prose with no secrets here')
        expect(value).to eq('Hello world, just plain prose with no secrets here')
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

      # Item 1: credential-scanner-hash-keys-not-scanned
      # EAV rows where the key column carries the credential name must be caught.
      context 'with credential-shaped Hash keys (EAV key column gap)' do
        it 'redacts a credential-shaped String key and preserves String key type' do
          # e.g. {key: "value"} shape where the *key* is the credential
          input = { 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' => 'some_value' }
          value, counts = scanner.scan(input)
          expect(value.keys.first).to eq('[REDACTED]')
          expect(counts[:stripe_secret_key]).to eq(1)
        end

        it 'redacts a credential-shaped Symbol key and preserves Symbol key type' do
          sym_key = :sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE
          input = { sym_key => 'some_value' }
          value, counts = scanner.scan(input)
          expect(value.keys.first).to eq(:'[REDACTED]')
          expect(counts[:stripe_secret_key]).to eq(1)
        end

        it 'leaves non-credential String keys unchanged' do
          input = { 'safe_key' => 'hello' }
          value, = scanner.scan(input)
          expect(value.keys.first).to eq('safe_key')
        end

        it 'leaves non-credential Symbol keys unchanged' do
          input = { safe_key: 'hello' }
          value, = scanner.scan(input)
          expect(value.keys.first).to eq(:safe_key)
        end

        it 'leaves non-string, non-symbol keys (e.g. Integer) unchanged' do
          input = { 42 => 'some_value' }
          value, = scanner.scan(input)
          expect(value.keys.first).to eq(42)
        end

        it 'scans both key and value independently' do
          # Both key and value carry credentials — both must be redacted
          input = { 'AKIAIOSFODNN7EXAMPLE' => 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE' }
          value, counts = scanner.scan(input)
          expect(value.keys.first).to eq('[REDACTED]')
          expect(value.values.first).to eq('[REDACTED]')
          expect(counts[:aws_access_key_id]).to eq(1)
          expect(counts[:stripe_secret_key]).to eq(1)
        end
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
        expect(value.dig('records', 1, 'value')).to eq('[REDACTED]')
        expect(counts[:stripe_secret_key]).to eq(1)
        expect(counts[:stripe_connect_account_id]).to eq(1)
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
        expect(value['rows'][0][2]).to eq('[REDACTED]')
        expect(counts[:stripe_secret_key]).to eq(1)
        expect(counts[:stripe_connect_account_id]).to eq(1)
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

  describe 'with a secret_index' do
    let(:secret_index) do
      Woods::Console::CredentialIndex.new(
        secrets: %w[twilio_auth_token_xyzzyplugh hand_rolled_hmac_seed_value]
      )
    end

    it 'redacts an indexed secret whose shape matches no pattern' do
      scanner = described_class.new(secret_index: secret_index)
      value, counts = scanner.scan('webhook secret = twilio_auth_token_xyzzyplugh today')
      expect(value).to include('[REDACTED:credential]')
      expect(value).not_to include('twilio_auth_token_xyzzyplugh')
      expect(counts[:credential_index]).to eq(1)
    end

    it 'still applies shape patterns to other strings in the same scan' do
      scanner = described_class.new(secret_index: secret_index)
      value, counts = scanner.scan(
        twilio: 'twilio_auth_token_xyzzyplugh',
        stripe: 'sk_live_51Sx7cbE0QMvj9FH5xhCjCEIl6TDZXZRpfYE'
      )
      expect(value[:twilio]).to eq('[REDACTED:credential]')
      expect(value[:stripe]).to eq('[REDACTED]')
      expect(counts[:credential_index]).to eq(1)
      expect(counts[:stripe_secret_key]).to eq(1)
    end

    it 'treats an empty index the same as no index' do
      empty = Woods::Console::CredentialIndex.new(secrets: [])
      scanner = described_class.new(secret_index: empty)
      _, counts = scanner.scan('twilio_auth_token_xyzzyplugh')
      expect(counts[:credential_index]).to be_nil
    end
  end

  describe '.patterns' do
    it 'returns the full pattern name list' do
      expect(described_class.patterns).to include(
        :stripe_secret_key, :stripe_publishable_key, :stripe_webhook_secret,
        :stripe_connect_account_id, :klaviyo_private_key,
        :aws_access_key_id, :github_fine_grained_pat, :github_token,
        :google_oauth_token, :jwt_token, :pem_private_key_block, :slack_token,
        :sendgrid_api_key, :mailgun_api_key,
        :anthropic_api_key, :openai_api_key,
        :shopify_access_token, :square_access_token, :paypal_access_token,
        :salesforce_access_token, :launchdarkly_sdk_key, :launchdarkly_mobile_key,
        :hubspot_private_app_token, :brevo_api_key, :brevo_smtp_key, :kit_api_key,
        :twilio_account_sid, :twilio_api_key_sid, :twilio_verify_service_sid
      )
    end
  end
end
