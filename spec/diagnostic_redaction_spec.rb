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
  end

  describe '.register' do
    it "removes a registered URL's password wherever it appears, decoded or not" do
      described_class.register("postgres://#{user}:pw%2F#{marker}@#{host}/#{database}")

      redacted = described_class.redact("auth failed with pw/#{marker}, pw%2F#{marker}")

      expect(redacted).to eq('auth failed with [REDACTED], [REDACTED]')
    end

    it 'removes the password of a registered configuration hash, and of a connection pool' do
      db_config = double('DbConfig', configuration_hash: { password: password, host: 'db' })
      described_class.register(double('Connection', pool: double('Pool', db_config: db_config)))
      described_class.register('url' => "postgres://u:other-#{marker}@db/x")

      expect(described_class.redact("got #{password} and other-#{marker}")).not_to include(marker)
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
