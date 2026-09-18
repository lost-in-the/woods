# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'stringio'
require 'woods/agent_configuration/cli'

RSpec.describe Woods::AgentConfiguration::CLI do
  let(:directory) { Dir.mktmpdir('woods-agent-cli') }
  let(:output) { StringIO.new }
  let(:errors) { StringIO.new }
  let(:evidence) { { 'version' => '2.0.0.alpha', 'tools' => Woods::AgentConfiguration::Preflight::REQUIRED_TOOLS } }
  let(:preflight) { ->(_launcher) { evidence } }
  let(:cli) { described_class.new(stdout: output, stderr: errors, preflight: preflight) }
  let(:selection) { ['--client', 'claude', '--scope', 'project', '--root', directory] }

  before { File.write(File.join(directory, 'Gemfile'), "source 'https://rubygems.org'\n") }
  after { FileUtils.remove_entry(directory) }

  def run_command(*arguments)
    output.truncate(0)
    output.rewind
    errors.truncate(0)
    errors.rewind
    cli.run(arguments.flatten + selection)
  end

  def plan(operation, name, *extra)
    path = File.join(directory, name)
    expect(run_command(operation, '--plan', path, *extra)).to eq(0), errors.string
    path
  end

  it 'previews, applies, repeats, updates and removes through the same saved plan interface' do
    config = File.join(directory, '.mcp.json')
    instructions = File.join(directory, 'AGENTS.md')
    File.write(config, "{\r\n  \"mcpServers\": {\"other\": {\"command\": \"other\"}},\r\n  \"hooks\": []\r\n}\r\n")
    File.write(instructions, "# Existing\r\nKeep this café.\r\n")
    original = File.binread(instructions)
    before = File.binread(config)
    setup = plan('setup', 'setup.json', '--instructions', 'AGENTS.md', '--diff')
    expect(File.binread(config)).to eq(before)
    expect(File.binread(instructions)).to eq(original)
    expect(File.stat(setup).mode & 0o777).to eq(0o600)
    expect(errors.string).to include('woods-mcp-start', 'woods:managed:start')
    expect(run_command('apply', setup)).to eq(0), errors.string
    expect(run_command('apply', setup)).to eq(0)
    expect(JSON.parse(output.string)['result']).to eq('already_applied')
    repeated = plan('setup', 'repeated.json', '--instructions', 'AGENTS.md')
    expect(JSON.parse(File.read(repeated))['changes']).to be_empty
    updated = plan('update', 'update.json', '--instructions', 'CLAUDE.md', '--index', 'tmp/other')
    expect(run_command('apply', updated)).to eq(0)
    expect(File.binread(instructions)).to eq(original)
    expect(File.read(config)).to include('tmp/other')
    removal = plan('remove', 'remove.json')
    expect(run_command('apply', removal)).to eq(0)
    expect(JSON.parse(File.read(config))).to eq('mcpServers' => { 'other' => { 'command' => 'other' } }, 'hooks' => [])
    expect(File.read(config)).not_to match(/(?<!\r)\n/)
    expect(File).not_to exist(File.join(directory, 'CLAUDE.md'))
  end

  it 'returns actionable conflicts without mutating a changed configuration or overwriting a plan' do
    setup = plan('setup', 'setup.json')
    expect(run_command('setup', '--plan', setup)).to eq(1)
    expect(errors.string).to include('File exists')
    File.write(File.join(directory, '.mcp.json'), '{"user_changed":true}')
    expect(run_command('apply', setup)).to eq(1)
    expect(errors.string).to include('Changed since preview')
    expect(File.read(File.join(directory, '.mcp.json'))).to eq('{"user_changed":true}')
  end

  it 'requires explicit client and scope and refuses managed targets as plan paths' do
    expect(cli.run(['setup', '--root', directory, '--plan', File.join(directory, 'plan.json')])).to eq(1)
    expect(run_command('setup', '--plan', File.join(directory, '.mcp.json'))).to eq(1)
    expect(errors.string).to include('Plan output must differ')
    expect(File).not_to exist(File.join(directory, '.mcp.json'))
  end

  it 'does not boot or require the application bundle when removing owned configuration' do
    setup = plan('setup', 'setup.json')
    expect(run_command('apply', setup)).to eq(0)
    File.unlink(File.join(directory, 'Gemfile'))
    removal = plan('remove', 'remove.json')
    expect(run_command('apply', removal)).to eq(0)
    expect(File).not_to exist(File.join(directory, '.mcp.json'))
  end
end
