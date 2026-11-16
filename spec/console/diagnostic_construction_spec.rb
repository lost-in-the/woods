# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
require 'stringio'
require 'logger'
require 'json'
require 'woods'
require 'woods/console/server'

RSpec.describe Woods::Console::Server, 'diagnostic construction' do
  before do
    config = Woods::Configuration.new
    config.console_credential_defense_enabled = true
    config.console_credential_rotation_warning = true
    allow(Woods).to receive(:configuration).and_return(config)
    stub_const('Woods::Console::Server::SCANNERS', Woods::Console::CredentialScannerRegistry.new)
  end

  it 'emits the stale-file warning without constructing a scanner recursively' do
    Dir.mktmpdir('woods-stale-credentials') do |dir|
      root = Pathname.new(dir)
      FileUtils.mkdir_p(root.join('config'))
      path = root.join('config/credentials.yml.enc')
      File.write(path, 'fictional file marker')
      later = Woods::Console::CredentialIndex::PROCESS_START + 60
      File.utime(later, later, path)
      app = double('app', root: root, credentials: double('credentials', config: {}))
      stub_const('Rails', Module.new { define_singleton_method(:application) { app } })
      logger = double('logger')
      allow(described_class).to receive(:structured_logger).and_return(logger)
      expect(logger).to receive(:warn).with('console.credential_index.stale',
                                            hash_including(credentials_file: path.to_s))
      expect(described_class).not_to receive(:handle_observability_failure)
      described_class.build_diagnostic_scanner
    end
  end

  it 'builds one response index and one shared diagnostic index per embedded server' do
    app = double('app', credentials: double('credentials', config: {}))
    stub_const('Rails', Module.new { define_singleton_method(:application) { app } })
    expect(Woods::Console::CredentialIndex).to receive(:build).with(rails_app: app).twice.and_call_original
    described_class.build_embedded(
      model_validator: Woods::Console::ModelValidator.new(registry: {}),
      safe_context: Woods::Console::SafeContext.new, read_tools_enabled: true
    )
  end

  describe 'when Rails credentials cannot be read at boot' do
    let(:stream) { StringIO.new }
    let(:planted) { 'fictional-planted-diagnostic-text-5512' }
    let(:missing_key) do
      Class.new(StandardError) { define_singleton_method(:name) { 'ActiveSupport::EncryptedFile::MissingKeyError' } }
    end
    let(:credentials) { double('unreadable credentials') }
    let(:safe_context) { Woods::Console::SafeContext.new }
    let(:marker) { '[DIAGNOSTIC_OMITTED: credential index unavailable]' }

    before do
      Woods.configuration.console_credential_rotation_warning = false
      allow(credentials).to receive(:config).and_raise(missing_key, 'fictional missing key')
      app = double('app', credentials: credentials)
      logger = Logger.new(stream)
      stub_const('Rails', Module.new do
        define_singleton_method(:application) { app }
        define_singleton_method(:logger) { logger }
      end)
      allow(safe_context).to receive(:execute) { raise ArgumentError, "lookup failed for #{planted}" }
    end

    def boot
      described_class.build_embedded(
        model_validator: Woods::Console::ModelValidator.new(registry: { 'Fixture' => ['id'] }),
        safe_context: safe_context, read_tools_enabled: true
      )
    end

    def call(server)
      request = { jsonrpc: '2.0', id: 1, method: 'tools/call',
                  params: { name: 'console_count', arguments: { model: 'Fixture' } } }
      JSON.parse(server.handle_json(JSON.generate(request))).fetch('result')
    end

    def rotated_app(config)
      double('rotated app', credentials: double('rotated credentials', config: config))
    end

    it 'starts and logs a fixed marker in place of diagnostic text' do
      result = call(boot)
      expect(result.fetch('isError')).to be(true)
      expect(result.to_json).to include('execution failed (details logged server-side)')
      expect(stream.string).to include(marker)
      expect(stream.string).not_to include(planted)
      expect(stream.string).not_to include('ArgumentError')
    end

    it 'stays unavailable when a rebuild cannot read credentials' do
      server = boot
      expect { described_class.rebuild_credential_index(rails_app: Rails.application) }.to raise_error(missing_key)
      call(server)
      expect(stream.string).to include(marker)
      expect(stream.string).not_to include(planted)
    end

    it 'scans diagnostic text again after a successful rebuild' do
      server = boot
      described_class.rebuild_credential_index(rails_app: rotated_app({}))
      call(server)
      expect(stream.string).to include(planted)
      expect(stream.string).not_to include(marker)
    end

    it 'redacts a fresh credential once a rebuild reads one' do
      server = boot
      described_class.rebuild_credential_index(rails_app: rotated_app({ key: planted }))
      call(server)
      expect(stream.string).to include('[REDACTED:credential]')
      expect(stream.string).not_to include(planted)
      expect(stream.string).not_to include(marker)
    end

    it 'logs scanned diagnostic text when the credentials read as an empty mapping' do
      allow(credentials).to receive(:config).and_return({})
      call(boot)
      expect(stream.string).to include(planted)
      expect(stream.string).not_to include(marker)
    end

    it 'keeps pattern-only diagnostics without reading credentials when credential defense is disabled' do
      Woods.configuration.console_credential_defense_enabled = false
      pattern_value = 'sk_test_abcdefghijklmnopqrstuvwxyz'
      allow(safe_context).to receive(:execute) { raise ArgumentError, "#{planted} #{pattern_value}" }
      call(boot)
      expect(credentials).not_to have_received(:config)
      expect(stream.string).to include(planted, '[REDACTED]')
      expect(stream.string).not_to include(pattern_value)
      expect(stream.string).not_to include(marker)
    end
  end
end
