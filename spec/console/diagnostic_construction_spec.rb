# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'
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
end
