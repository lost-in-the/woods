# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/extractors/config_source_guard'

RSpec.describe Woods::Extractors::ConfigSourceGuard do
  describe '.redact' do
    it 'replaces credential-shaped text and leaves the rest of the source alone' do
      source = <<~RUBY
        Ledger.api_key = "sk_live_#{'a1B2' * 8}"
        Ledger.timeout = 5
      RUBY

      expect(described_class.redact(source)).to eq(<<~RUBY)
        Ledger.api_key = "[REDACTED]"
        Ledger.timeout = 5
      RUBY
    end

    it 'replaces the userinfo of a URL in any scheme and keeps the host' do
      source = "source 'https://ledger:plaintext-marker@gems.example/private'\n"

      expect(described_class.redact(source)).to eq("source 'https://[REDACTED]@gems.example/private'\n")
    end

    it 'replaces a database URL carrying a password' do
      redacted = described_class.redact("url = 'postgres://ledger:plaintext-marker@db.example/ledger'\n")

      expect(redacted).not_to include('marker')
    end

    it 'replaces the body of a private key block' do
      source = <<~RUBY
        KEY = <<~PEM
          -----BEGIN RSA PRIVATE KEY-----
          plaintext-marker-line-one
          plaintext-marker-line-two
          -----END RSA PRIVATE KEY-----
        PEM
        AFTER = 1
      RUBY

      redacted = described_class.redact(source)

      expect(redacted).not_to include('marker')
      expect(redacted).to include('KEY = <<~PEM', '[REDACTED]', 'AFTER = 1')
    end

    it 'withholds everything after an unterminated private key header' do
      redacted = described_class.redact("a = 1\n-----BEGIN PRIVATE KEY-----\nplaintext-marker\n")

      expect(redacted).to eq("a = 1\n[REDACTED]\n")
    end

    it 'resumes after a private key held on one line' do
      key = '-----BEGIN PRIVATE KEY-----plaintext-marker-----END PRIVATE KEY-----'
      redacted = described_class.redact("K = '#{key}'\nb = 2\n")

      expect(redacted).to eq("[REDACTED]\nb = 2\n")
    end

    it 'returns source without credentials unchanged' do
      source = "pin 'application'\nset :user, 'deploy'\nmail = 'ledger@example.test'\nratio = a ? b : c\n"

      expect(described_class.redact(source)).to eq(source)
    end
  end

  describe '.inside_root?' do
    let(:root) { Dir.mktmpdir }
    let(:outside) { Dir.mktmpdir }

    after { FileUtils.rm_rf([root, outside]) }

    it 'accepts a regular file and a symlink that stays under the root' do
      FileUtils.mkdir_p(File.join(root, 'config'))
      File.write(File.join(root, 'config/boot.rb'), '')
      File.symlink(File.join(root, 'config/boot.rb'), File.join(root, 'config/link.rb'))

      expect(described_class.inside_root?(File.join(root, 'config/boot.rb'), root)).to be(true)
      expect(described_class.inside_root?(File.join(root, 'config/link.rb'), root)).to be(true)
    end

    it 'refuses a symlink that leaves the root, a parent traversal and a missing file' do
      File.write(File.join(outside, 'boot.rb'), '')
      File.symlink(File.join(outside, 'boot.rb'), File.join(root, 'Gemfile'))

      expect(described_class.inside_root?(File.join(root, 'Gemfile'), root)).to be(false)
      expect(described_class.inside_root?(File.join(root, "../#{File.basename(outside)}/boot.rb"), root)).to be(false)
      expect(described_class.inside_root?(File.join(root, 'missing.rb'), root)).to be(false)
    end
  end
end
