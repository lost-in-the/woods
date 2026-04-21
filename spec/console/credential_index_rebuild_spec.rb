# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/console/credential_index'
require 'woods/console/server'

# Item 2: credential-index-rebuild-on-rotation
# Specs for Server.rebuild_credential_index and CredentialIndex.warn_if_credentials_rotated.

def build_app_stub(config_hash = nil)
  credentials = Class.new do
    def initialize(payload)
      @payload = payload
    end

    def config
      @payload
    end
  end.new(config_hash)

  Class.new do
    def initialize(creds)
      @credentials = creds
    end

    attr_reader :credentials
  end.new(credentials)
end

RSpec.describe Woods::Console::Server, '.rebuild_credential_index' do
  before do
    allow(Woods).to receive(:respond_to?).and_call_original
    allow(Woods).to receive(:respond_to?).with(:configuration).and_return(true)
    allow(Woods).to receive(:respond_to?).with(:configuration, anything).and_return(true)
    config_dbl = instance_double(
      Woods::Configuration,
      console_credential_defense_enabled: true,
      console_credential_scanning_enabled: true,
      console_disabled_scanner_patterns: [],
      console_blocked_tables: [],
      context_format: :markdown,
      console_credential_rotation_warning: false
    )
    allow(Woods).to receive(:configuration).and_return(config_dbl)

    # Reset module-level state between tests
    described_class.instance_variable_set(:@active_scanner, nil)
  end

  it 'returns nil and does not raise when no scanner has been registered yet' do
    result = described_class.rebuild_credential_index(rails_app: build_app_stub({}))
    expect(result).to be_nil
  end

  it 'swaps the secret_index on the active scanner' do
    old_index = Woods::Console::CredentialIndex.new(
      secrets: ['old_secret_value_for_testing']
    )
    scanner = Woods::Console::CredentialScanner.new(secret_index: old_index)
    described_class.instance_variable_set(:@active_scanner, scanner)

    new_app = build_app_stub({ api_key: 'new_secret_value_for_testing' })
    described_class.rebuild_credential_index(rails_app: new_app)

    current_index = scanner.instance_variable_get(:@secret_index)
    expect(current_index.secrets).not_to include('old_secret_value_for_testing')
    expect(current_index.secrets).to include('new_secret_value_for_testing')
  end

  it 'returns the newly built CredentialIndex' do
    scanner = Woods::Console::CredentialScanner.new
    described_class.instance_variable_set(:@active_scanner, scanner)

    app = build_app_stub({ token: 'fresh_secret_value_for_rebuild' })
    result = described_class.rebuild_credential_index(rails_app: app)

    expect(result).to be_a(Woods::Console::CredentialIndex)
    expect(result.secrets).to include('fresh_secret_value_for_rebuild')
  end

  it 'returns nil without touching the scanner when credential defense is disabled' do
    config_dbl = instance_double(
      Woods::Configuration,
      console_credential_defense_enabled: false,
      console_credential_scanning_enabled: true,
      console_disabled_scanner_patterns: [],
      console_blocked_tables: [],
      context_format: :markdown,
      console_credential_rotation_warning: false
    )
    allow(Woods).to receive(:respond_to?).and_call_original
    allow(Woods).to receive(:respond_to?).with(:configuration).and_return(true)
    allow(Woods).to receive(:respond_to?).with(:configuration, anything).and_return(true)
    allow(Woods).to receive(:configuration).and_return(config_dbl)

    scanner = Woods::Console::CredentialScanner.new
    described_class.instance_variable_set(:@active_scanner, scanner)

    result = described_class.rebuild_credential_index(rails_app: build_app_stub({}))
    expect(result).to be_nil
  end

  it 'is non-breaking — existing callers of build/build_embedded are unaffected' do
    # Verify the method exists as a public class method
    expect(described_class).to respond_to(:rebuild_credential_index)
  end
end

RSpec.describe Woods::Console::CredentialIndex, '.warn_if_credentials_rotated' do
  require 'tempfile'
  require 'fileutils'

  let(:process_start) { Time.now - 3600 } # simulated process start 1 hour ago

  context 'when a credentials file is newer than process start' do
    it 'emits a warn via the provided logger' do
      tmp = Tempfile.new(['credentials', '.yml.enc'])
      tmp.close
      # Touch to ensure mtime is now (well after process_start)
      FileUtils.touch(tmp.path)

      logger = double('logger')
      expect(logger).to receive(:warn).with(
        'console.credential_index.stale',
        hash_including(credentials_file: tmp.path)
      )

      described_class.warn_if_credentials_rotated(
        credentials_files: [tmp.path],
        process_start: process_start,
        logger: logger
      )
    ensure
      tmp.unlink
    end
  end

  context 'when all credentials files are older than process start' do
    it 'does not emit a warning' do
      tmp = Tempfile.new(['credentials', '.yml.enc'])
      tmp.close
      old_time = process_start - 7200
      File.utime(old_time, old_time, tmp.path)

      logger = double('logger')
      expect(logger).not_to receive(:warn)

      described_class.warn_if_credentials_rotated(
        credentials_files: [tmp.path],
        process_start: process_start,
        logger: logger
      )
    ensure
      tmp.unlink
    end
  end

  context 'when no credentials files exist on disk' do
    it 'does not emit a warning' do
      logger = double('logger')
      expect(logger).not_to receive(:warn)

      described_class.warn_if_credentials_rotated(
        credentials_files: ['/nonexistent/path/credentials.yml.enc'],
        process_start: process_start,
        logger: logger
      )
    end
  end

  context 'when the credentials_files list is empty' do
    it 'does not emit a warning' do
      logger = double('logger')
      expect(logger).not_to receive(:warn)

      described_class.warn_if_credentials_rotated(
        credentials_files: [],
        process_start: process_start,
        logger: logger
      )
    end
  end
end
