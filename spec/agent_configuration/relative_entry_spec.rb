# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'woods/agent_configuration/cli'
require 'woods/mcp/client_entry'
require 'generators/woods/mcp_configuration'

# A project-scope configuration is committed and shared: it names no absolute
# path, so it works unchanged in every checkout and worktree on every machine.
# User scope stays per-machine and keeps absolute paths.
RSpec.describe 'woods-agent-config relative project entries' do
  let(:directory) { File.realpath(Dir.mktmpdir('woods-agent-relative')) }
  let(:root) { File.join(directory, 'shop') }
  let(:output) { StringIO.new }
  let(:errors) { StringIO.new }
  let(:evidence) { { 'version' => '2.2.0', 'tools' => Woods::AgentConfiguration::Preflight::REQUIRED_TOOLS } }
  let(:probed) { [] }
  let(:preflight) do
    lambda do |launcher|
      probed << launcher
      evidence
    end
  end
  let(:cli) { Woods::AgentConfiguration::CLI.new(stdout: output, stderr: errors, preflight: preflight) }

  before do
    FileUtils.mkdir_p(File.join(root, '.git'))
    File.write(File.join(root, 'Gemfile'), "source 'https://rubygems.org'\n")
  end

  after { FileUtils.remove_entry(directory) }

  def path_free_failures(value, base = directory)
    case value
    when Hash then value.values.flat_map { |item| path_free_failures(item, base) }
    when Array then value.flat_map { |item| path_free_failures(item, base) }
    else [value].select { |text| absolute_text?(text, base) }
    end
  end

  def absolute_text?(text, base)
    text = text.to_s
    text.start_with?('/') || text.match?(%r{\A[A-Za-z]:[\\/]}) || text.include?(base) || text.include?('${')
  end

  def run(*arguments, scope: 'project')
    output.truncate(0)
    output.rewind
    errors.truncate(0)
    errors.rewind
    cli.run(arguments + ['--client', 'claude', '--scope', scope, '--root', root])
  end

  def plan(operation, name, *extra, scope: 'project')
    path = File.join(directory, name)
    code = run(operation, '--plan', path, *extra, scope: scope)
    [code, path]
  end

  def apply(path, scope: 'project')
    expect(run('apply', path, scope: scope)).to eq(0), errors.string
  end

  def written_entry(config = File.join(root, '.mcp.json'))
    JSON.parse(File.read(config)).dig('mcpServers', 'woods')
  end

  def receipt
    JSON.parse(File.read(File.join(root, '.woods-agent-config.json')))
  end

  describe 'the Launcher' do
    it 'writes the shared checkout-aware entry for project scope, host and compose' do
      host = Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative')
      compose = Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative', mode: 'compose',
                                                        service: 'web', container_root: '/app')

      expect(host.entry).to eq(Woods::MCP::ClientEntry.checkout)
      expect(compose.entry).to eq(Woods::MCP::ClientEntry.checkout(service: 'web'))
      [host, compose].each do |launcher|
        expect(path_free_failures(launcher.entry)).to be_empty
        expect(launcher.entry).not_to have_key('cwd')
        expect(launcher.entry.fetch('env', {})).not_to have_key('BUNDLE_GEMFILE')
        expect(launcher.intent).to include('entry_form' => 'relative')
      end
    end

    it 'prints the same entry from the install generator' do
      expect(Woods::Generators::McpConfiguration.entry)
        .to eq(Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative').entry)
      expect(Woods::Generators::McpConfiguration.entry(service: 'web'))
        .to eq(Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative', mode: 'compose',
                                                       service: 'web', container_root: '/app').entry)
    end

    it 'names another index, or an application below its checkout root, relative to that checkout' do
      application = File.join(root, 'apps', 'web')
      FileUtils.mkdir_p(application)
      File.write(File.join(application, 'Gemfile'), '')

      other = Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative', index: 'tmp/other index')
      nested = Woods::AgentConfiguration::Launcher.new(root: application, form: 'relative')
      compose = Woods::AgentConfiguration::Launcher.new(root: application, form: 'relative', mode: 'compose',
                                                        service: 'web', container_root: '/app/apps/web')

      expect(other.entry['env']).to eq('WOODS_OUTPUT' => 'tmp/other index')
      expect(nested.entry['env']).to eq('WOODS_OUTPUT' => 'apps/web/tmp/woods')
      expect(nested.entry).to eq(Woods::MCP::ClientEntry.for_root(application))
      expect(nested.entry.dig('args', 1)).to include('cd "$(git rev-parse --show-toplevel)"/apps/web || exit 1; ')
      expect(compose.entry.dig('args', 1)).to include('-e WOODS_OUTPUT=apps/web/tmp/woods web ')
      [other, nested, compose].each { |launcher| expect(path_free_failures(launcher.entry)).to be_empty }
    end

    it 'keeps the absolute entry for the absolute form, unchanged' do
      launcher = Woods::AgentConfiguration::Launcher.new(root: root)

      expect(launcher.entry).to eq('type' => 'stdio', 'command' => 'bundle',
                                   'args' => ['exec', 'woods-mcp-start', File.join(root, 'tmp/woods')],
                                   'env' => { 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') })
      expect(launcher.intent).to include('entry_form' => 'absolute')
    end

    it 'refuses a relative entry outside any git checkout and an unknown form' do
      FileUtils.rm_r(File.join(root, '.git'))

      expect { Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative') }
        .to raise_error(Woods::AgentConfiguration::Conflict, /not inside a git checkout.*--entry-form absolute/)
      expect { Woods::AgentConfiguration::Launcher.new(root: root, form: 'portable') }
        .to raise_error(Woods::AgentConfiguration::Conflict, /--entry-form relative or absolute/)
    end

    it 'probes the same launch as a relative entry: the checkout and the --checkout capability' do
      launcher = Woods::AgentConfiguration::Launcher.new(root: root, form: 'relative')

      expect(launcher.probe_command('probe').last(3)).to eq([File.join(root, 'tmp/woods'), root, 'relative'])
      expect(Woods::AgentConfiguration::Preflight::SCRIPT).to include("ARGV[2] == 'relative'", 'woods/mcp/index_wait',
                                                                      'checkout_root')
    end
  end

  describe 'a woods entry already in .mcp.json without a receipt' do
    def commit_entry(entry)
      File.write(File.join(root, '.mcp.json'), JSON.pretty_generate('mcpServers' => { 'woods' => entry }))
    end

    it 'adopts one byte-identical to what setup writes, and records this checkout\'s own receipt' do
      commit_entry(Woods::MCP::ClientEntry.checkout)
      before = File.read(File.join(root, '.mcp.json'))

      code, path = plan('setup', 'adopt.json')
      expect(code).to eq(0), errors.string
      result = JSON.parse(output.string)
      expect(result).to include('adopted' => true)
      expect(result.fetch('notes').join).to include('adopted')
      apply(path)

      expect(File.read(File.join(root, '.mcp.json'))).to eq(before)
      expect(receipt).to include('entry' => Woods::MCP::ClientEntry.checkout)
      expect(receipt.dig('layout', 'root')).to eq(root)
      expect(receipt['created_files']).not_to include(File.join(root, '.mcp.json'))
    end

    it 'still refuses an identical absolute entry, which names one machine' do
      launcher = Woods::AgentConfiguration::Launcher.new(root: root)
      commit_entry(launcher.entry)

      code, = plan('setup', 'adopt.json', '--entry-form', 'absolute')

      expect(code).to eq(1)
      expect(errors.string).to include('already exists without a Woods receipt')
    end

    it 'still refuses a different entry' do
      commit_entry(Woods::MCP::ClientEntry.checkout(service: 'web'))

      code, = plan('setup', 'adopt.json')

      expect(code).to eq(1)
      expect(errors.string).to include('already exists without a Woods receipt')
    end

    it 'removes only the adopted entry, leaving the file it did not create' do
      File.write(File.join(root, '.mcp.json'),
                 JSON.pretty_generate('mcpServers' => { 'woods' => Woods::MCP::ClientEntry.checkout,
                                                        'other' => { 'command' => 'other' } }))
      _, path = plan('setup', 'adopt.json')
      apply(path)

      _, removal = plan('remove', 'remove.json')
      apply(removal)

      expect(JSON.parse(File.read(File.join(root, '.mcp.json'))))
        .to eq('mcpServers' => { 'other' => { 'command' => 'other' } })
      expect(File).not_to exist(File.join(root, '.woods-agent-config.json'))
    end
  end

  describe 'a Compose entry' do
    it 'says the service working_dir must be the application root and worktrees need a pinned project name' do
      code, = plan('setup', 'compose.json', '--mode', 'compose', '--service', 'web', '--container-root', '/app')

      expect(code).to eq(0), errors.string
      expect(JSON.parse(output.string).fetch('notes').join)
        .to include('working_dir', 'application root', 'COMPOSE_PROJECT_NAME')
    end
  end

  describe 'setup and update' do
    # apply keeps a lock beside every file it manages (it serializes on their
    # inodes), so the notes name .gitignore lines that cover every one.
    it 'names .gitignore lines covering the receipt and every file apply leaves beside its targets' do
      code, path = plan('setup', 'setup.json')
      notes = JSON.parse(output.string).fetch('notes').join
      apply(path)
      left = Dir.children(root) - %w[.git Gemfile .mcp.json CLAUDE.md AGENTS.md]
      patterns = %w[.woods-agent-config.json* *.woods.lock]

      expect(code).to eq(0)
      expect(notes).to include(*patterns)
      expect(left).not_to be_empty
      expect(left.reject { |name| patterns.any? { |glob| File.fnmatch?(glob, name, File::FNM_DOTMATCH) } }).to eq([])
    end

    it 'writes a relative project entry by default, records the form, and says so' do
      code, path = plan('setup', 'setup.json')

      expect(code).to eq(0), errors.string
      expect(JSON.parse(output.string)).to include('entry_form' => 'relative')
      expect(JSON.parse(output.string).fetch('notes').join).to include('.woods-agent-config.json', '.gitignore')
      apply(path)
      expect(written_entry).to eq(Woods::MCP::ClientEntry.checkout)
      expect(path_free_failures(written_entry)).to be_empty
      expect(receipt.dig('intent', 'entry_form')).to eq('relative')
    end

    it 'keeps the absolute form, and says why, for an application outside any git checkout' do
      FileUtils.rm_r(File.join(root, '.git'))

      code, path = plan('setup', 'setup.json')

      expect(code).to eq(0), errors.string
      expect(JSON.parse(output.string)).to include('entry_form' => 'absolute')
      expect(JSON.parse(output.string).fetch('notes').join).to include('not inside a git checkout')
      apply(path)
      expect(written_entry.dig('args', -1)).to eq(File.join(root, 'tmp/woods'))
      code, = plan('setup', 'explicit.json', '--entry-form', 'relative')
      expect(code).to eq(1)
      expect(errors.string).to include('not inside a git checkout')
    end

    it 'keeps user scope per-machine and absolute, and refuses a relative user entry' do
      config_dir = File.join(directory, 'client-config')
      FileUtils.mkdir_p(config_dir)
      stub_const('ENV', ENV.to_h.merge('CLAUDE_CONFIG_DIR' => config_dir))

      code, path = plan('setup', 'user.json', scope: 'user')
      expect(code).to eq(0), errors.string
      expect(JSON.parse(output.string)).to include('entry_form' => 'absolute')
      apply(path, scope: 'user')
      expect(written_entry(File.join(config_dir, '.claude.json')).dig('env', 'BUNDLE_GEMFILE'))
        .to eq(File.join(root, 'Gemfile'))

      code, = plan('setup', 'relative-user.json', '--entry-form', 'relative', scope: 'user')
      expect(code).to eq(1)
      expect(errors.string).to include('project scope')
    end

    describe 'an installation written in the absolute form' do
      before do
        _, path = plan('setup', 'absolute.json', '--entry-form', 'absolute')
        apply(path)
      end

      it 'is left absolute by a repeated setup with no flag' do
        code, path = plan('setup', 'repeat.json')

        expect(code).to eq(0), errors.string
        expect(JSON.parse(File.read(path))['changes']).to be_empty
        expect(JSON.parse(output.string)).to include('entry_form' => 'absolute')
        expect(JSON.parse(output.string).fetch('notes').join).to include('update --entry-form relative')
      end

      it 'is left absolute by an update with no flag, as by a receipt that records no form' do
        receipt_path = File.join(root, '.woods-agent-config.json')
        legacy = receipt
        legacy['intent'].delete('entry_form')
        File.write(receipt_path, JSON.pretty_generate(legacy))

        code, path = plan('update', 'update.json', '--index', 'tmp/other')
        expect(code).to eq(0), errors.string
        apply(path)

        expect(written_entry.dig('args', -1)).to eq(File.join(root, 'tmp/other'))
      end

      it 'refuses a setup that asks for the relative form, pointing at an explicit update' do
        code, = plan('setup', 'migrate.json', '--entry-form', 'relative')

        expect(code).to eq(1)
        expect(errors.string).to include('absolute form', 'update', '--entry-form relative')
        expect(written_entry.dig('env', 'BUNDLE_GEMFILE')).to eq(File.join(root, 'Gemfile'))
      end

      it 'migrates to the relative form on update --entry-form relative, records it, and still removes cleanly' do
        code, path = plan('update', 'migrate.json', '--entry-form', 'relative')
        expect(code).to eq(0), errors.string
        apply(path)

        expect(written_entry).to eq(Woods::MCP::ClientEntry.checkout)
        expect(receipt.dig('intent', 'entry_form')).to eq('relative')
        expect(receipt['created_files']).to include(File.join(root, '.mcp.json'))

        _, removal = plan('remove', 'remove.json')
        apply(removal)
        expect(File).not_to exist(File.join(root, '.mcp.json'))
        expect(File).not_to exist(File.join(root, '.woods-agent-config.json'))
      end
    end
  end
end
