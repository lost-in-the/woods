# frozen_string_literal: true

require 'spec_helper'
require 'timeout'
require 'woods/extractors/rake_shell_redaction'

RSpec.describe Woods::Extractors::RakeShellRedaction do
  def redact(command)
    described_class.redact(command)
  end

  describe '.redact' do
    it 'redacts URL userinfo, with or without a password' do
      expect(redact('curl https://deploy:Wd8kq2Lm9x@ledger.example.test/export'))
        .to eq('curl https://[REDACTED]@ledger.example.test/export')
      expect(redact('git clone https://Wd8kq2Lm9xQ7zP3vB6nT@git.example.test/widgets.git'))
        .to eq('git clone https://[REDACTED]@git.example.test/widgets.git')
    end

    it 'redacts the value of a credential-named environment assignment' do
      expect(redact('PGPASSWORD=Wd8kq2Lm9x pg_dump widgets')).to eq('PGPASSWORD=[REDACTED] pg_dump widgets')
      expect(redact('export LEDGER_API_TOKEN="Wd8kq2Lm9xQ7zP3vB6nT" && bin/sync'))
        .to eq('export LEDGER_API_TOKEN="[REDACTED]" && bin/sync')
      expect(redact('env DB_PASSWORD=hunter2 bin/migrate')).to eq('env DB_PASSWORD=[REDACTED] bin/migrate')
    end

    it 'redacts a sensitive-named assignment only when the value reads as a generated token' do
      expect(redact('SESSION_KEY=Wd8kq2Lm9xQ7zP3vB6nTr4Ky8 bin/serve')).to eq('SESSION_KEY=[REDACTED] bin/serve')
      expect(redact('SKIP_AUTH=1 RAILS_ENV=production bin/serve')).to eq('SKIP_AUTH=1 RAILS_ENV=production bin/serve')
    end

    it 'keeps an assignment whose value is a reference, not a literal' do
      expect(redact('PGPASSWORD=$LEDGER_DB_PASSWORD pg_dump widgets'))
        .to eq('PGPASSWORD=$LEDGER_DB_PASSWORD pg_dump widgets')
      expect(redact("PGPASSWORD=\#{ENV.fetch('LEDGER_DB_PASSWORD')} pg_dump widgets"))
        .to eq("PGPASSWORD=\#{ENV.fetch('LEDGER_DB_PASSWORD')} pg_dump widgets")
    end

    it 'redacts a bearer or basic token, quoted or not' do
      expect(redact('curl -H "Authorization: Bearer Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "Authorization: Bearer [REDACTED]" https://api.example.test')
      expect(redact('curl -H Authorization: basic d2lkZ2V0OnNlY3JldA== https://api.example.test'))
        .to eq('curl -H Authorization: basic [REDACTED] https://api.example.test')
    end

    it 'redacts a credential-named header value' do
      expect(redact('curl -H "X-Api-Key: Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "X-Api-Key: [REDACTED]" https://api.example.test')
    end

    it 'redacts the password of -u and --user' do
      expect(redact('curl -u deploy:Wd8kq2Lm9x https://ledger.example.test'))
        .to eq('curl -u deploy:[REDACTED] https://ledger.example.test')
      expect(redact('curl --user=deploy:Wd8kq2Lm9x https://ledger.example.test'))
        .to eq('curl --user=deploy:[REDACTED] https://ledger.example.test')
      expect(redact('curl -u deploy https://ledger.example.test')).to eq('curl -u deploy https://ledger.example.test')
    end

    it 'redacts the value of a credential-named flag' do
      expect(redact('bin/sync --api-token=Wd8kq2Lm9xQ7zP3vB6nT --verbose'))
        .to eq('bin/sync --api-token=[REDACTED] --verbose')
      expect(redact('mysqldump --password hunter2 widgets')).to eq('mysqldump --password [REDACTED] widgets')
    end

    it 'redacts a credential-named query parameter' do
      expect(redact('curl https://api.example.test/hook?token=Wd8kq2Lm9xQ7zP3vB6nT&ledger=7'))
        .to eq('curl https://api.example.test/hook?token=[REDACTED]&ledger=7')
    end

    it 'redacts a known credential shape anywhere' do
      expect(redact('bin/notify ghp_Wd8kq2Lm9xQ7zP3vB6nTr4Ky8Hc5Jf1Ae0Xb')).to eq('bin/notify [REDACTED]')
    end

    it 'leaves ordinary commands alone' do
      ['yarn run graph-codegen', "docker compose exec app \#{command}", 'git rev-parse HEAD',
       'bin/rails runner "Widget.where(password_reset: true).count"',
       'curl -X POST https://api.example.test'].each do |command|
        expect(redact(command)).to eq(command)
      end
    end
  end

  describe 'on adversarial input' do
    around do |example|
      previous = Regexp.respond_to?(:timeout) ? Regexp.timeout : nil
      Regexp.timeout = 1 if Regexp.respond_to?(:timeout=)
      Timeout.timeout(5) { example.run }
    ensure
      Regexp.timeout = previous if Regexp.respond_to?(:timeout=)
    end

    it 'redacts 50,000 assignments in one line' do
      expect(redact('PASSWORD=Wd8kq2Lm9x ' * 50_000).scan('[REDACTED]').size).to eq(50_000)
    end

    it 'passes over 10,000 near-matches of every rule' do
      line = 'PASSWORD Bearer -u --password= ?token &key= X-Api-Key Authorization: ' * 10_000

      expect(redact(line)).to be_a(String)
    end

    it 'reads one 50,000-character token' do
      expect(redact("PGPASSWORD=#{'a1' * 25_000}")).to eq('PGPASSWORD=[REDACTED]')
    end

    it 'reads a value wrapped in 50,000 quotes on each side' do
      quotes = "'" * 50_000

      redacted = redact("PGPASSWORD=#{quotes}Wd8kq2Lm9x#{quotes}")

      expect(redacted).to include('[REDACTED]')
      expect(redacted).not_to include('Wd8kq2Lm9x')
    end

    it 'reads a token of 50,000 query parameters' do
      query = Array.new(50_000) { |i| "p#{i}=v" }.join('&')

      expect(redact("curl https://api.example.test/x?#{query}&token=Wd8kq2Lm9x")).to end_with('&token=[REDACTED]')
    end
  end
end
