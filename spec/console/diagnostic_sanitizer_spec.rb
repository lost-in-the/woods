# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/diagnostic_sanitizer'

RSpec.describe Woods::Console::DiagnosticSanitizer do
  it 'retains useful bounded context and masks recognizable credentials' do
    result = described_class.new.text('adapter failed with sk_test_abcdefghijklmnopqrstuvwxyz')
    expect(result).to eq('adapter failed with [REDACTED]')
  end

  it 'never returns raw text when scanning fails' do
    scanner = double('scanner')
    allow(scanner).to receive(:scan).and_raise(ArgumentError, 'fictional secret')
    expect(described_class.new(scanner: scanner).text('fixture')).to eq('[REDACTION_FAILED]')
  end

  it 'bounds bytes rather than characters without slicing multibyte text' do
    expect(described_class.new.text('é' * 4097)).to eq(described_class::OMITTED)
  end

  it 'scans a credential ending exactly at the inclusive diagnostic byte boundary' do
    secret = 'fictional-boundary-credential'
    index = Woods::Console::CredentialIndex.new(secrets: [secret])
    scanner = Woods::Console::CredentialScanner.new(secret_index: index)
    input = ('x' * (8192 - secret.bytesize)) + secret
    expect(described_class.new(scanner: scanner).text(input)).to end_with('[REDACTED:credential]')
    expect(described_class.new(scanner: scanner).text("#{input}x")).to eq(described_class::OMITTED)
  end

  it 'omits oversized text before invoking the scanner' do
    scanner = double('scanner')
    expect(scanner).not_to receive(:scan)
    expect(described_class.new(scanner: scanner).text('x' * 8193)).to eq(described_class::OMITTED)
  end

  it 'fails closed on invalid encoding' do
    expect(described_class.new.text("\xff".b.force_encoding('UTF-8'))).to eq('[REDACTION_FAILED]')
  end

  it 'bounds expanded scanned text as well' do
    scanner = double(scan: ['x' * 8193, {}])
    expect(described_class.new(scanner: scanner).text('small')).to eq(described_class::OMITTED)
  end
end
