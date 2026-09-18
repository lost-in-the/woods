# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'active_support'
require 'active_support/encrypted_configuration'
require 'active_support/core_ext/hash/keys'
require 'tmpdir'
require 'fileutils'
require 'woods/console/credential_index'

RSpec.describe Woods::Console::CredentialIndex, 'fresh encrypted snapshots' do
  around do |example|
    Dir.mktmpdir('woods-credential-refresh') do |root|
      @root = root
      example.run
    end
  end

  def encrypted_config
    ActiveSupport::EncryptedConfiguration.new(
      config_path: File.join(@root, 'credentials.yml.enc'),
      key_path: File.join(@root, 'master.key'), env_key: 'WOODS_SYNTHETIC_TEST_KEY',
      raise_if_missing_key: false
    )
  end

  def app_for(credentials)
    Struct.new(:credentials).new(credentials)
  end

  it 'refreshes a real encrypted configuration without altering its memoized config' do
    File.write(File.join(@root, 'master.key'), ActiveSupport::EncryptedFile.generate_key)
    encrypted_config.write({ secret: 'synthetic-original-value' }.to_yaml)
    original = encrypted_config
    cached = original.config
    encrypted_config.write({ secret: 'synthetic-replacement-value' }.to_yaml)

    index = described_class.refresh(rails_app: app_for(original))

    expect(index.match?('synthetic-replacement-value')).to be true
    expect(original.config).to equal(cached)
    expect(cached[:secret]).to eq('synthetic-original-value')
  end

  it 'preserves permissive missing-key boot while an explicit refresh raises' do
    app = app_for(encrypted_config)

    expect(described_class.build(rails_app: app)).to be_empty
    expect { described_class.refresh(rails_app: app) }.to raise_error(ActiveSupport::EncryptedFile::MissingKeyError)
  end

  it 'preserves permissive missing-content boot while an explicit refresh raises' do
    File.write(File.join(@root, 'master.key'), ActiveSupport::EncryptedFile.generate_key)
    app = app_for(encrypted_config)

    expect(described_class.build(rails_app: app)).to be_empty
    expect { described_class.refresh(rails_app: app) }.to raise_error(ActiveSupport::EncryptedFile::MissingContentError)
  end

  it 'preserves config-only collaborators without requiring Rails file attributes' do
    config = { nested: ['synthetic-custom-value'] }
    credentials = Struct.new(:config).new(config)

    expect(described_class.refresh(rails_app: app_for(credentials)).match?('synthetic-custom-value')).to be true
  end
end
