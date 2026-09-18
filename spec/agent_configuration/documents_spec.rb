# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/agent_configuration/document'
require 'woods/agent_configuration/layout'
require 'woods/agent_configuration/managed_section'

RSpec.describe 'Owned agent configuration documents' do
  let(:directory) { Dir.mktmpdir('woods-agent-config') }

  after { FileUtils.remove_entry(directory) }

  it 'keeps a project layout entirely inside its explicitly selected worktree' do
    layout = Woods::AgentConfiguration::Layout.new(root: directory, scope: 'project', home: '/unrelated-home')
    expect(layout.allowed_paths).to all(start_with("#{directory}/"))
    expect(layout.config_path).to eq(File.join(directory, '.mcp.json'))
  end

  it 'matches the real Claude default and custom user configuration locations' do
    default = Woods::AgentConfiguration::Layout.new(root: directory, scope: 'user', home: directory, config_dir: nil)
    expect(default.config_path).to eq(File.join(directory, '.claude.json'))
    expect(default.instruction_path('CLAUDE.md')).to eq(File.join(directory, '.claude/CLAUDE.md'))
    custom = Woods::AgentConfiguration::Layout.new(root: directory, scope: 'user', home: '/unused',
                                                   config_dir: File.join(directory, 'client'))
    expect(custom.config_path).to eq(File.join(directory, 'client/.claude.json'))
    expect { custom.instruction_path('AGENTS.md') }.to raise_error(Woods::AgentConfiguration::Conflict)
  end

  it 'rejects symlink files and parents without reading their targets' do
    path = File.join(directory, 'linked')
    File.symlink('/etc', path)
    expect { Woods::AgentConfiguration::Document.new(File.join(path, 'passwd')) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Symlink/)
  end

  it 'rejects a FIFO promptly instead of blocking on open' do
    path = File.join(directory, 'fifo')
    system('mkfifo', path, exception: true)
    expect { Woods::AgentConfiguration::Document.new(path) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /regular file/)
  end

  it 'preserves unrelated JSON values and CRLF when adding an entry' do
    path = File.join(directory, 'settings.json')
    File.write(path, "{\r\n\t\"mcpServers\": {\"other\": {\"command\": \"unrelated\"}},\r\n\t\"hooks\": [1]\r\n}\r\n")
    File.chmod(0o640, path)
    document = Woods::AgentConfiguration::Document.new(path)
    data = document.json
    data['mcpServers']['woods'] = { 'command' => 'bundle' }
    encoded = document.encode_json(data)
    expect(encoded).not_to match(/(?<!\r)\n/)
    expect(JSON.parse(encoded)).to include('hooks' => [1],
                                           'mcpServers' => include('other' => { 'command' => 'unrelated' }))
    expect(document.mode).to eq(0o640)
  end

  it 'returns identical bytes when the JSON content is already correct' do
    path = File.join(directory, 'settings.json')
    File.write(path, '{ "mcpServers" : {} }')
    document = Woods::AgentConfiguration::Document.new(path)
    expect(document.encode_json(document.json)).to eq(File.read(path))
  end

  it 'rejects malformed JSON instead of replacing it with an empty configuration' do
    path = File.join(directory, 'settings.json')
    File.write(path, '{broken')
    expect { Woods::AgentConfiguration::Document.new(path).json }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Malformed JSON/)
  end

  it 'updates idempotently and removes only its own section, including its added separator' do
    original = "# Other instructions\r\n\r\nKeep café intact."
    section = Woods::AgentConfiguration::ManagedSection
    installed, receipt = section.change(original, previous: nil)
    repeated, = section.change(installed, previous: receipt)
    expect(repeated).to eq(installed)
    expect(installed).not_to match(/(?<!\r)\n/)
    modified_outside = installed.sub('Other instructions', 'Updated instructions')
    removed, = section.change(modified_outside, previous: receipt, remove: true)
    expect(removed).to eq(original.sub('Other instructions', 'Updated instructions'))
  end

  it 'refuses user-modified, duplicate, and unowned instruction sections' do
    section = Woods::AgentConfiguration::ManagedSection
    installed, receipt = section.change('', previous: nil)
    [installed.sub('Call', 'Never call'), installed + installed, ''].each do |content|
      expect { section.change(content, previous: receipt) }.to raise_error(Woods::AgentConfiguration::Conflict)
    end
    expect { section.change(installed, previous: nil) }.to raise_error(Woods::AgentConfiguration::Conflict, /Unowned/)
  end
end
