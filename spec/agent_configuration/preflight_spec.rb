# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'rbconfig'
require 'woods/agent_configuration/preflight'
require 'woods/agent_configuration/launcher'

RSpec.describe Woods::AgentConfiguration::Preflight do
  let(:directory) { Dir.mktmpdir('woods-agent-probe') }
  after { FileUtils.remove_entry(directory) }

  def launcher(script)
    double('launcher', root: directory, probe_environment: { 'BUNDLE_FROZEN' => 'true' },
                       probe_command: [RbConfig.ruby, '-e', script])
  end

  it 'checks actual child output and rejects missing capabilities' do
    payload = JSON.generate(version: '2.0.0.alpha', tools: described_class::REQUIRED_TOOLS)
    probe = launcher("abort unless ENV['BUNDLE_FROZEN'] == 'true'; puts #{payload.inspect}")
    expect(described_class.new.call(probe)).to include('version' => '2.0.0.alpha')
    expect { described_class.new.call(launcher('puts %q({"version":"old","tools":[]})')) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /lacks required/)
  end

  it 'bounds a hanging subprocess and a failed or malformed response' do
    expect { described_class.new(timeout: 0.1).call(launcher('sleep 30')) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /exceeded/)
    expect { described_class.new.call(launcher('warn "broken bundle"; exit 1')) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /broken bundle/)
    expect { described_class.new.call(launcher('puts "not JSON"')) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /valid JSON/)
  end

  it 'builds exact host and compose argv with a frozen bundle during read-only preflight' do
    File.write(File.join(directory, 'Gemfile'), '')
    host = Woods::AgentConfiguration::Launcher.new(root: directory, index: 'tmp/index')
    expect(host.entry['args']).to eq(['exec', 'woods-mcp-start', File.join(directory, 'tmp/index')])
    expect(host.probe_environment).to include('BUNDLE_FROZEN' => 'true')
    container = Woods::AgentConfiguration::Launcher.new(root: directory, mode: 'compose', service: 'web',
                                                        container_root: '/app')
    expect(container.entry['args']).to eq(['compose', '--project-directory', directory, 'exec', '-T', '-w',
                                           '/app', 'web', 'bundle', 'exec', 'woods-mcp-start', '/app/tmp/woods'])
    expect(container.probe_command('probe')).to include('-e', 'BUNDLE_FROZEN=true', 'probe')
    expect { Woods::AgentConfiguration::Launcher.new(root: directory, index: '../elsewhere') }
      .to raise_error(Woods::AgentConfiguration::Conflict)
  end
end
