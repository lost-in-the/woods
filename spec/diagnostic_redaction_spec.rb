# frozen_string_literal: true

require 'spec_helper'
require 'woods/diagnostic_redaction'

RSpec.describe Woods::DiagnosticRedaction do
  # Every fake credential carries the marker, so one search proves none survived.
  let(:marker) { 'fakesecretmarker' }
  let(:password) { "pw-#{marker}" }
  let(:user) { "user-#{marker}" }
  let(:host) { "db-#{marker}.internal" }
  let(:database) { "woods-#{marker}" }

  after { described_class.clear! }

  describe '.redact without registered values' do
    {
      'a URL' => ->(s) { "could not connect to postgres://#{s[:user]}:#{s[:password]}@#{s[:host]}:5432/x" },
      'key=value conninfo' => lambda { |s|
        "PG::ConnectionBad: host=#{s[:host]} port=5432 dbname=#{s[:database]} user=#{s[:user]} " \
          "password='#{s[:password]}' connect_timeout=5"
      },
      'a symbol-keyed hash inspect' => lambda { |s|
        { adapter: 'postgresql', host: s[:host], username: s[:user], password: s[:password],
          database: s[:database] }.inspect
      },
      'a string-keyed hash inspect' => lambda { |s|
        { 'host' => s[:host], 'user' => s[:user], 'password' => s[:password], 'database' => s[:database] }.inspect
      },
      'libpq connection text' => lambda { |s|
        %(connection to server at "#{s[:host]}" (10.9.8.7), port 5432 failed: FATAL:  password authentication ) +
          %(failed for user "#{s[:user]}"\nFATAL:  database "#{s[:database]}" does not exist)
      },
      'MySQL access text' => ->(s) { "Access denied for user '#{s[:user]}'@'#{s[:host]}' (using password: YES)" },
      'Active Record connection error text' => lambda { |s|
        "There is an issue connecting with your hostname: #{s[:host]}.\n\nThere is an issue connecting to your " \
          "database with your username/password, username: #{s[:user]}.\n\nPlease check your database configuration."
      },
      'unquoted conninfo values that start with or hold punctuation' => lambda { |s|
        "password=;#{s[:password]} user=x,#{s[:user]} host=db&#{s[:host]} dbname=d)#{s[:database]}"
      },
      'colon values that start with or hold punctuation' => lambda { |s|
        "password: ;#{s[:password]} username: x,#{s[:user]}. hostname: (#{s[:host]})."
      },
      'libpq name resolution text' => lambda { |s|
        %(could not translate host name "#{s[:host]}" to address: Name or service not known\n) +
          %(could not parse network address "#{s[:host]}": bad\n) +
          %(could not translate Unix-domain socket path "/run/#{s[:database]}/.s.PGSQL.5432" to address: bad)
      },
      'MariaDB connection text' => lambda { |s|
        "Can't connect to server on '#{s[:host]}' (111); " \
          "Can't connect to local server through socket '/run/#{s[:database]}.sock' (2)"
      }
    }.each do |form, build|
      it "removes every connection detail from #{form}" do
        text = build.call(password: password, user: user, host: host, database: database)
        expect(text).to include(marker)

        redacted = described_class.redact(text)

        expect(redacted).not_to include(marker)
        expect(redacted).to include('[REDACTED]')
      end
    end

    it 'keeps the parts of a message that carry no connection detail' do
      text = 'connection to server at "h" (10.9.8.7), port 5432 failed: Connection refused'

      expect(described_class.redact(text))
        .to eq('connection to server at "[REDACTED]" ([REDACTED]), port 5432 failed: Connection refused')
    end

    it 'ends an unquoted value at whitespace, and keeps the sentence and the keys that name no database' do
      text = "host=db port=5432 sslmode=require; username: u.\nhostname: h, then retry"

      expect(described_class.redact(text))
        .to eq("host=[REDACTED] port=5432 sslmode=require; username: [REDACTED].\nhostname: [REDACTED], then retry")
    end

    it 'keeps host name, network address and socket wording that quotes nothing' do
      text = 'host name resolution failed; the network address and socket path come from woods.json'

      expect(described_class.redact(text)).to eq(text)
    end

    it 'redacts text that is not valid UTF-8, and text in another encoding, without raising' do
      [
        "\xFFpassword=#{password}".force_encoding(Encoding::UTF_8),
        "host=#{host} café".b,
        "host=#{host} café".encode(Encoding::UTF_16LE)
      ].each do |text|
        redacted = described_class.redact(text)

        expect(redacted).not_to include(marker)
        expect(redacted).to be_valid_encoding
      end
    end

    it 'keeps valid UTF-8 text unchanged' do
      text = 'Résumé of the index: woods.json names no database'

      expect(described_class.redact(text)).to eq(text)
    end
  end

  describe '.register' do
    it "removes a registered URL's password wherever it appears, decoded or not" do
      described_class.register("postgres://#{user}:pw%2F#{marker}@#{host}/#{database}")

      redacted = described_class.redact("auth failed with pw/#{marker}, pw%2F#{marker}")

      expect(redacted).to eq('auth failed with [REDACTED], [REDACTED]')
    end

    it "removes a registered URL's password as Active Record decodes it, + kept, and as a form decodes it" do
      described_class.register("postgres://u:a+b%2F-#{marker}@db/x")
      described_class.register("postgres://u:c%2Bd-#{marker}@db/x")

      redacted = described_class.redact("got a+b/-#{marker}, a b/-#{marker} and c+d-#{marker}")

      expect(redacted).to eq('got [REDACTED], [REDACTED] and [REDACTED]')
    end

    it 'removes the password of a registered configuration hash, and of a connection pool' do
      db_config = double('DbConfig', configuration_hash: { password: password, host: 'db' })
      described_class.register(double('Connection', pool: double('Pool', db_config: db_config)))
      described_class.register('url' => "postgres://u:other-#{marker}@db/x")

      expect(described_class.redact("got #{password} and other-#{marker}")).not_to include(marker)
    end

    it 'removes a registered URL the URI parser rejected, as its error message quotes it' do
      url = "postgres://app #{user}:#{password}@#{host}/#{database}"
      described_class.register(url)
      message = begin
        URI.parse(url)
      rescue URI::InvalidURIError => e
        e.message
      end
      expect(message).to include(marker)

      expect(described_class.redact(message)).not_to include(marker)
    end

    it 'removes every part of registered values that overlap or contain one another' do
      described_class.register(password: 'rotate')
      described_class.register(password: "rotate-#{marker}")
      described_class.register(password: 'a-long-registered-prefix-shared')
      described_class.register(password: "shared-#{marker}")

      text = "used rotate-#{marker} and rotate, then a-long-registered-prefix-shared-#{marker}"

      redacted = described_class.redact(text)

      expect(redacted).to eq('used [REDACTED] and [REDACTED], then [REDACTED]')
    end

    it 'removes a registered non-ASCII password, however it and the text are encoded' do
      described_class.register("postgres://u:p%C3%A4ss-#{marker}@db/x")
      described_class.register(password: "über-#{marker}".b.force_encoding(Encoding::US_ASCII))

      redacted = described_class.redact("auth failed with päss-#{marker} and über-#{marker}".b)

      expect(redacted).to eq('auth failed with [REDACTED] and [REDACTED]')
    end

    it 'leaves a word that only contains a registered value, and the names it was not given' do
      described_class.register('postgres://postgres:postgres@localhost/woods')

      expect(described_class.redact('the postgresql adapter read woods.json'))
        .to eq('the postgresql adapter read woods.json')
    end
  end

  it 'removes the password of a registered Active Record 6.0 pool, whose configuration is on its spec' do
    pool = double('Pool', spec: double('Spec', config: { password: password, host: 'db' }))
    described_class.register(pool)

    expect(described_class.redact("got #{password}")).to eq('got [REDACTED]')
  end

  describe '.redact_details' do
    it 'removes password values and redacts strings, keeping keys and other values' do
      details = { vector_store: :pgvector, password: password, url: "postgres://#{user}@#{host}/x",
                  nested: { list: ["password=#{password}"] } }

      redacted = described_class.redact_details(details)

      expect(redacted.inspect).not_to include(marker)
      expect(redacted).to include(vector_store: :pgvector, password: '[REDACTED]', url: 'postgres://[REDACTED]')
    end

    it "keeps a provider mismatch's host-provider details, which name no database" do
      details = { host: 'Woods::Embedding::Provider::OpenAI/text-embedding-3-small', stored: 'Ollama/nomic' }

      expect(described_class.redact_details(details)).to eq(details)
    end
  end

  it "removes a non-database URL's whole credential run, through its last @ before the host" do
    text = "redis://app:#{password}@after-#{marker}@cache/0 and https://#{user}@qdrant.example:6333/x"

    expect(described_class.redact(text)).to eq('redis://[REDACTED]@cache/0 and https://[REDACTED]@qdrant.example:6333/x')
  end

  it "keeps an @ in a URL's path, query or fragment" do
    text = 'https://example.com/users/a@b?ref=c@d#e@f and http://ollama.internal:11434/a@b'

    expect(described_class.redact(text)).to eq(text)
  end

  it 'keeps ordinary boot messages that name no database' do
    [
      'Host provider OpenAI/text-embedding-3-small does not match stored provider Ollama/nomic-embed-text.',
      'http://ollama.internal:11434: Connection refused',
      'Unknown metadata_store: cassandra: woods.json names a store adapter this gem cannot build.'
    ].each { |message| expect(described_class.redact(message)).to eq(message) }
  end

  it 'describes an error as its class and redacted message' do
    error = StandardError.new("password=#{password}")

    expect(described_class.describe(error)).to eq('StandardError: password=[REDACTED]')
  end
end
