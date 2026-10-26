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

    it 'redacts every word of a quoted value after a credential flag or user flag' do
      expect(redact('mysqldump --password "multi word hunter2" widgets'))
        .to eq('mysqldump --password "[REDACTED]" widgets')
      expect(redact('curl -u "deploy:pass hunter2" https://ledger.example.test'))
        .to eq('curl -u "deploy:[REDACTED]" https://ledger.example.test')
    end

    it 'redacts a header whose value is attached to the name' do
      expect(redact('curl -H "Authorization:Bearer Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "Authorization:Bearer [REDACTED]" https://api.example.test')
      expect(redact('curl -H "X-Api-Key:Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "X-Api-Key:[REDACTED]" https://api.example.test')
    end

    it 'redacts an attached user and password' do
      expect(redact('curl -udeploy:hunter2 https://ledger.example.test'))
        .to eq('curl -udeploy:[REDACTED] https://ledger.example.test')
    end

    it 'redacts the password flag of tools that take one, and keeps ports' do
      expect(redact('mysql -u root -phunter2 widgets')).to eq('mysql -u root -p[REDACTED] widgets')
      expect(redact('sshpass -p hunter2 ssh deploy@ledger.example.test'))
        .to eq('sshpass -p [REDACTED] ssh deploy@ledger.example.test')
      expect(redact('docker login -p hunter2 registry.example.test'))
        .to eq('docker login -p [REDACTED] registry.example.test')
      expect(redact('redis-cli -a hunter2 ping')).to eq('redis-cli -a [REDACTED] ping')
      expect(redact('docker run -p 8080:80 widgets && ssh -p 2222 ledger.example.test && mkdir -p tmp/cache'))
        .to eq('docker run -p 8080:80 widgets && ssh -p 2222 ledger.example.test && mkdir -p tmp/cache')
    end

    it 'redacts a credential inside a single-quoted JSON body' do
      expect(redact(%(curl -d '{"password":"hunter2","ledger":7}' https://api.example.test)))
        .to eq(%(curl -d '{"password":"[REDACTED]","ledger":7}' https://api.example.test))
      expect(redact(%(curl -d '{"api_token": "hunter2"}' https://api.example.test)))
        .to eq(%(curl -d '{"api_token": "[REDACTED]"}' https://api.example.test))
    end

    it 'redacts inside a quoted command nested in another quoted command' do
      expect(redact(%(bash -c "curl -H 'Authorization: Bearer Wd8kq2Lm9xQ7zP3vB6nTr4Ky8' https://api.example.test")))
        .to eq(%(bash -c "curl -H 'Authorization: Bearer [REDACTED]' https://api.example.test"))
      expect(redact(%(ssh deploy@ledger.example.test "PGPASSWORD=hunter2 pg_dump widgets")))
        .to eq(%(ssh deploy@ledger.example.test "PGPASSWORD=[REDACTED] pg_dump widgets"))
    end

    it 'applies the argument rules to a quoted argument that holds a quote but no space' do
      expect(redact(%(curl -d "token=Wd8kq2Lm9x'x" https://api.example.test)))
        .to eq(%(curl -d "token=[REDACTED]" https://api.example.test))
    end

    it 'redacts a numeric password where -p never means a port' do
      expect(redact('mysql -p123456 widgets')).to eq('mysql -p[REDACTED] widgets')
      expect(redact('sshpass -p 123456 ssh ledger.example.test')).to eq('sshpass -p [REDACTED] ssh ledger.example.test')
    end

    it 'redacts the credential after any Authorization scheme' do
      expect(redact('curl -H "Authorization: token Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "Authorization: token [REDACTED]" https://api.example.test')
      expect(redact('curl -H "Authorization:Digest Wd8kq2Lm9xQ7zP3vB6nTr4Ky8" https://api.example.test'))
        .to eq('curl -H "Authorization:Digest [REDACTED]" https://api.example.test')
    end

    it 'redacts what echo or printf pipes into --password-stdin' do
      expect(redact('echo hunter2 | docker login -u deploy --password-stdin registry.example.test'))
        .to eq('echo [REDACTED] | docker login -u deploy --password-stdin registry.example.test')
      expect(redact('echo -n "two words" | docker login --password-stdin'))
        .to eq('echo -n [REDACTED] | docker login --password-stdin')
      expect(redact('echo done && bin/report')).to eq('echo done && bin/report')
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
    # What these examples guard is that the scan stays linear. An absolute
    # time budget cannot tell that apart from a slow runner (SimpleCov line
    # instrumentation alone adds seconds), so each example builds its input at
    # a tenth of its size and at full size and compares thread CPU time:
    # linear growth is about 10x, quadratic about 100x. The wall-clock timeout
    # is only a backstop against a scan that never returns.
    let(:max_growth) { 25 }
    let(:cpu_floor) { 0.05 }

    def cpu_time
      started = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
      result = yield
      [Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID) - started, result]
    end

    # @yield [count] builds the input for +count+ repetitions and returns what redact returned
    # @return the result of the full-size run
    def at_scale(full)
      small = Array.new(3) { cpu_time { yield(full / 10) }.first }.min
      large, result = cpu_time { yield(full) }
      growth = large / [small, cpu_floor].max
      expect(growth).to be < max_growth,
                        "10x input took #{growth.round(1)}x the CPU (#{small.round(3)}s -> #{large.round(3)}s)"
      result
    end

    around do |example|
      previous = Regexp.respond_to?(:timeout) ? Regexp.timeout : nil
      Regexp.timeout = 1 if Regexp.respond_to?(:timeout=)
      Timeout.timeout(60) { example.run }
    ensure
      Regexp.timeout = previous if Regexp.respond_to?(:timeout=)
    end

    it 'redacts 50,000 assignments in one line' do
      redacted = at_scale(50_000) { |count| redact('PASSWORD=Wd8kq2Lm9x ' * count) }

      expect(redacted.scan('[REDACTED]').size).to eq(50_000)
    end

    it 'passes over 10,000 near-matches of every rule' do
      redacted = at_scale(10_000) do |count|
        redact('PASSWORD Bearer -u --password= ?token &key= X-Api-Key Authorization: ' * count)
      end

      expect(redacted).to be_a(String)
    end

    it 'reads one 50,000-character token' do
      redacted = at_scale(25_000) { |count| redact("PGPASSWORD=#{'a1' * count}") }

      expect(redacted).to eq('PGPASSWORD=[REDACTED]')
    end

    it 'reads a value wrapped in 50,000 quotes on each side' do
      redacted = at_scale(50_000) do |count|
        quotes = "'" * count
        redact("PGPASSWORD=#{quotes}Wd8kq2Lm9x#{quotes}")
      end

      expect(redacted).to include('[REDACTED]')
      expect(redacted).not_to include('Wd8kq2Lm9x')
    end

    it 'reads 50,000 quoted arguments and an unterminated quote' do
      redacted = at_scale(50_000) do |count|
        redact("mysql #{%('{"password":"Wd8kq2Lm9x"}' "a b" -phunter2 ) * count}\"unterminated")
      end

      expect(redacted).not_to include('Wd8kq2Lm9x', 'hunter2')
    end

    it 'reads quotes nested 50,000 deep' do
      redacted = at_scale(25_000) do |count|
        redact("#{'"\'' * count}PGPASSWORD=hunter2#{'\'"' * count}")
      end

      expect(redacted).to be_a(String)
    end

    it 'reads a token of 50,000 query parameters' do
      redacted = at_scale(50_000) do |count|
        query = Array.new(count) { |i| "p#{i}=v" }.join('&')
        redact("curl https://api.example.test/x?#{query}&token=Wd8kq2Lm9x")
      end

      expect(redacted).to end_with('&token=[REDACTED]')
    end
  end
end
