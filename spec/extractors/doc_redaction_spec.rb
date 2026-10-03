# frozen_string_literal: true

require 'spec_helper'
require 'woods/extractors/doc_redaction'

RSpec.describe Woods::Extractors::DocRedaction do
  # Synthetic values in the shapes the Console scanner knows.
  let(:stripe_key) { "sk_test_#{'a1B2' * 6}" }
  let(:aws_key) { "AKIA#{'ABCD1234' * 2}" }

  def redact(source, front_matter: [], front_matter_lines: nil)
    described_class.new.call(source, front_matter: front_matter, front_matter_lines: front_matter_lines)
  end

  it 'redacts the credential shapes the Console scanner redacts and counts them' do
    text, counts = redact("# Setup\n\nexport STRIPE=#{stripe_key}\nAWS id `#{aws_key}`\n")

    expect(text).to eq("# Setup\n\nexport STRIPE=[REDACTED]\nAWS id `[REDACTED]`\n")
    expect(counts).to eq('aws_access_key_id' => 1, 'stripe_secret_key' => 1)
  end

  it 'redacts a connection string with a password' do
    text, counts = redact("DATABASE_URL=postgres://ledger:hunter2@db.internal/ledger\n")

    expect(text).to eq("DATABASE_URL=[REDACTED]\n")
    expect(counts).to eq('database_url_with_password' => 1)
  end

  it 'redacts every line of a PEM private key block and keeps the line count' do
    source = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEow\nIBAAK\n-----END RSA PRIVATE KEY-----\nafter\n"
    text, counts = redact(source)

    expect(text).to eq("before\n[REDACTED]\n[REDACTED]\n[REDACTED]\n[REDACTED]\nafter\n")
    expect(counts).to eq('pem_private_key_block' => 1)
  end

  it 'redacts an unterminated PEM block through the end of the document' do
    text, = redact("-----BEGIN PRIVATE KEY-----\nMIIEow\nstill key")

    expect(text).to eq("[REDACTED]\n[REDACTED]\n[REDACTED]")
  end

  it 'redacts the value of a credential-named front matter key and leaves other keys' do
    source = "---\ntitle: Widget API\napi_token: plainvalue\n---\nbody\n"
    front_matter = [{ key: 'title', value: 'Widget API', line: 2 }, { key: 'api_token', value: 'plainvalue', line: 3 }]
    text, counts = redact(source, front_matter: front_matter, front_matter_lines: 1..4)

    expect(text).to eq("---\ntitle: Widget API\napi_token: [REDACTED]\n---\nbody\n")
    expect(counts).to eq('front_matter_value' => 1)
  end

  it 'replaces a token too long to scan in bounded time' do
    blob = 'eyJ-' * 2000
    text, counts = redact("data #{blob} end\n")

    expect(text).to eq("data [REDACTED] end\n")
    expect(counts).to eq('oversize_token' => 1)
  end

  it 'leaves ordinary prose, identifiers and line endings untouched' do
    source = "# Ledger\r\n\r\nUUID 123e4567-e89b-12d3-a456-426614174000 and `Widget::Importer`.\r\n"

    expect(redact(source)).to eq([source, {}])
  end

  it 'names credential-like front matter keys' do
    credential = %w[password API_KEY client_secret auth_token private-key]

    expect(credential.select { |key| described_class.credential_key?(key) }).to eq(credential)
    expect(%w[title owner tags author].select { |key| described_class.credential_key?(key) }).to eq([])
  end
end
