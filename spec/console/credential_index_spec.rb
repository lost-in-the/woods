# frozen_string_literal: true

require 'spec_helper'
require 'woods/console/credential_index'

RSpec.describe Woods::Console::CredentialIndex do
  # Minimal stub that mirrors `Rails.application.credentials.config` —
  # a Hash returned by a `.credentials.config` call chain.
  def build_app(config_hash = nil, raise_with: nil)
    credentials = Class.new do
      def initialize(payload, raise_with)
        @payload = payload
        @raise_with = raise_with
      end

      def config
        raise @raise_with if @raise_with

        @payload
      end
    end.new(config_hash, raise_with)

    Class.new do
      def initialize(creds)
        @credentials = creds
      end

      attr_reader :credentials
    end.new(credentials)
  end

  # Stand-ins for the Rails-side error classes — we match by class *name*
  # so the spec doesn't need to load ActiveSupport. The real classes have
  # the same fully-qualified names; class-name matching keeps the
  # production code decoupled from Rails version drift.
  def named_error(name)
    klass = Class.new(StandardError)
    klass.define_singleton_method(:name) { name }
    klass
  end

  describe '.build' do
    it 'collects every string leaf at or above MIN_LENGTH' do
      app = build_app({
                        api_key: 'secret_value_with_lots_of_chars',
                        nested: { token: 'another_secret_token_value' }
                      })
      index = described_class.build(rails_app: app)
      expect(index.secrets).to include('secret_value_with_lots_of_chars',
                                       'another_secret_token_value')
    end

    it 'drops strings shorter than MIN_LENGTH' do
      app = build_app({ env: 'production', short: 'abc',
                        long: 'long_enough_to_keep_this_one' })
      index = described_class.build(rails_app: app)
      expect(index.secrets).to contain_exactly('long_enough_to_keep_this_one')
    end

    it 'walks arrays' do
      app = build_app({ allowed_keys: %w[short_one another_long_secret_value
                                         yet_another_long_secret] })
      index = described_class.build(rails_app: app)
      expect(index.secrets).to contain_exactly('another_long_secret_value',
                                               'yet_another_long_secret')
    end

    it 'deduplicates repeated values' do
      app = build_app({ a: 'duplicate_secret_value', b: 'duplicate_secret_value' })
      index = described_class.build(rails_app: app)
      expect(index.secrets.size).to eq(1)
    end

    it 'returns an empty index when the credentials store is missing its key' do
      missing_key = named_error('ActiveSupport::EncryptedConfiguration::MissingKeyError')
      app = build_app(raise_with: missing_key.new('no key'))
      index = described_class.build(rails_app: app)
      expect(index).to be_empty
    end

    it 'returns an empty index when the credentials file is corrupt' do
      bad_message = named_error('ActiveSupport::MessageEncryptor::InvalidMessage')
      app = build_app(raise_with: bad_message.new('garbled'))
      index = described_class.build(rails_app: app)
      expect(index).to be_empty
    end

    it 're-raises unrelated errors so they surface to the caller' do
      app = build_app(raise_with: ArgumentError.new('something else'))
      expect { described_class.build(rails_app: app) }.to raise_error(ArgumentError)
    end
  end

  describe '#match?' do
    let(:index) do
      described_class.new(secrets: %w[real_secret_value_xxxxxxxx
                                      twilio_auth_token_yyyyyyyy])
    end

    it 'finds an exact match' do
      expect(index.match?('real_secret_value_xxxxxxxx')).to be true
    end

    it 'finds a substring match' do
      expect(index.match?('value: real_secret_value_xxxxxxxx')).to be true
    end

    it 'returns false on a string without any secret' do
      expect(index.match?('not in the index')).to be false
    end

    it 'returns false on non-strings' do
      expect(index.match?(nil)).to be false
      expect(index.match?(42)).to be false
    end

    it 'returns false when the index is empty' do
      expect(described_class.new(secrets: []).match?('anything')).to be false
    end
  end

  describe '#redact' do
    let(:index) do
      described_class.new(secrets: %w[real_secret_value_xxxxxxxx
                                      twilio_auth_token_yyyyyyyy])
    end

    it 'replaces a matched secret with the credential marker' do
      result = index.redact('value: real_secret_value_xxxxxxxx')
      expect(result).to eq('value: [REDACTED:credential]')
    end

    it 'replaces every occurrence' do
      result = index.redact(
        'a=real_secret_value_xxxxxxxx b=twilio_auth_token_yyyyyyyy'
      )
      expect(result).to eq('a=[REDACTED:credential] b=[REDACTED:credential]')
    end

    it 'returns the input unchanged when no secret appears' do
      expect(index.redact('hello world')).to eq('hello world')
    end

    it 'returns the input unchanged on an empty index' do
      empty = described_class.new(secrets: [])
      expect(empty.redact('real_secret_value_xxxxxxxx'))
        .to eq('real_secret_value_xxxxxxxx')
    end
  end

  describe '#empty?' do
    it 'is true when no secrets were collected' do
      expect(described_class.new(secrets: []).empty?).to be true
    end

    it 'is false when secrets are present' do
      expect(described_class.new(secrets: ['indexed_secret_value']).empty?).to be false
    end
  end
end
