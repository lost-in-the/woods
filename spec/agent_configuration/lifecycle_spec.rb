# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/agent_configuration/layout'
require 'woods/agent_configuration/planner'
require 'woods/agent_configuration/applier'

RSpec.describe 'Agent configuration lifecycle' do
  let(:directory) { Dir.mktmpdir('woods-owned-config') }
  let(:layout) { Woods::AgentConfiguration::Layout.new(root: directory, scope: 'project', config_dir: nil) }
  let(:entry) { { 'command' => 'bundle', 'args' => ['exec', 'woods-mcp-start', '/app/tmp/woods'] } }
  let(:applier) { Woods::AgentConfiguration::Applier.new(layout: layout) }

  after { FileUtils.remove_entry(directory) }

  def plan(operation = 'setup', **options)
    Woods::AgentConfiguration::Planner.new(layout: layout, operation: operation, entry: entry,
                                           instructions: ['CLAUDE.md'], **options).call
  end

  it 'previews without writing any target and applies exactly the serialized plan' do
    preview = plan
    expect(Dir.children(directory)).to be_empty
    path = File.join(directory, 'preview.json')
    File.write(path, JSON.generate(preview.data))
    restored = Woods::AgentConfiguration::Plan.load(path)
    expect(applier.apply(restored)).to eq('applied')
    expect(JSON.parse(File.read(layout.config_path)).fetch('mcpServers')).to eq('woods' => entry)
    expect(File.read(layout.instruction_path('CLAUDE.md'))).to include('woods:managed:start')
    expect(applier.apply(restored)).to eq('already_applied')
    expect(plan.data.fetch('changes')).to be_empty
  end

  it 'updates an owned entry and removes only owned content after unrelated user edits' do
    File.write(layout.config_path,
               JSON.generate('mcpServers' => { 'other' => { 'command' => 'existing' } }, 'hooks' => [1]))
    File.write(layout.instruction_path('CLAUDE.md'), "# Existing\r\nKeep me.\r\n")
    applier.apply(plan)
    new_entry = entry.merge('args' => ['exec', 'woods-mcp-start', '/app/other-index'])
    update = Woods::AgentConfiguration::Planner.new(layout: layout, operation: 'update', entry: new_entry).call
    applier.apply(update)
    settings = JSON.parse(File.read(layout.config_path))
    settings['new_setting'] = true
    File.write(layout.config_path, JSON.generate(settings))
    applier.apply(plan('remove'))
    expect(JSON.parse(File.read(layout.config_path))).to eq(
      'mcpServers' => { 'other' => { 'command' => 'existing' } }, 'hooks' => [1], 'new_setting' => true
    )
    expect(File.read(layout.instruction_path('CLAUDE.md'))).to eq("# Existing\r\nKeep me.\r\n")
    expect(File).not_to exist(layout.receipt_path)
  end

  it 'deletes newly created empty files but retains pre-existing empty instruction files' do
    File.write(layout.instruction_path('CLAUDE.md'), '')
    applier.apply(plan)
    applier.apply(plan('remove'))
    expect(File).not_to exist(layout.config_path)
    expect(File.read(layout.instruction_path('CLAUDE.md'))).to eq('')
    expect(plan('remove').data.fetch('changes')).to be_empty
  end

  it 'refuses name collisions rather than taking ownership of an existing server' do
    File.write(layout.config_path, JSON.generate('mcpServers' => { 'woods' => entry }))
    expect { plan }.to raise_error(Woods::AgentConfiguration::Conflict, /without a Woods receipt/)
    expect(File).not_to exist(layout.receipt_path)
  end

  it 'refuses changed managed content even when removing an installation' do
    applier.apply(plan)
    path = layout.instruction_path('CLAUDE.md')
    File.write(path, File.read(path).sub('Call', 'Never call'))
    expect { plan('remove') }.to raise_error(Woods::AgentConfiguration::Conflict, /edited/)
    expect(File).to exist(layout.config_path)
  end

  it 'checks all before-hashes before writing the first target' do
    preview = plan
    File.write(layout.instruction_path('CLAUDE.md'), 'New user instructions')
    expect { applier.apply(preview) }.to raise_error(Woods::AgentConfiguration::Conflict, /Changed since preview/)
    expect(File).not_to exist(layout.config_path)
    expect(File.read(layout.instruction_path('CLAUDE.md'))).to eq('New user instructions')
  end

  it 'detects permission changes made after preview' do
    File.write(layout.config_path, '{}')
    File.chmod(0o600, layout.config_path)
    preview = plan
    File.chmod(0o640, layout.config_path)
    expect { applier.apply(preview) }.to raise_error(Woods::AgentConfiguration::Conflict, /Changed since preview/)
    expect(File.stat(layout.config_path).mode & 0o777).to eq(0o640)
  end

  it 'rejects a plan aimed outside the selected scope' do
    preview = plan
    preview.data.fetch('changes').first['path'] = '/outside/.mcp.json'
    expect { applier.apply(preview) }.to raise_error(Woods::AgentConfiguration::Conflict, /out-of-scope/)
    expect(Dir.children(directory)).to be_empty
  end

  it 'rolls back files already written when a later write fails' do
    written = 0
    writer = lambda do |path, content, **options|
      written += 1
      raise IOError, 'injected failure' if written == 3

      Woods::AtomicFile.write(path, content, **options)
    end
    failing = Woods::AgentConfiguration::Applier.new(layout: layout, writer: writer)
    expect { failing.apply(plan) }.to raise_error(Woods::AgentConfiguration::Conflict, /original files were restored/)
    expect(File).not_to exist(layout.config_path)
    expect(File).not_to exist(layout.instruction_path('CLAUDE.md'))
    expect(File).not_to exist("#{layout.receipt_path}.pending")
  end

  it 'retains a recovery journal if a concurrent edit makes automatic rollback unsafe' do
    preview = plan
    writer = lambda do |path, content, **options|
      Woods::AtomicFile.write(path, content, **options)
      File.write(layout.config_path, '{"client_changed":true}') if path == layout.instruction_path('CLAUDE.md')
      raise IOError, 'interrupted' if path == layout.instruction_path('CLAUDE.md')
    end
    failing = Woods::AgentConfiguration::Applier.new(layout: layout, writer: writer)
    expect do
      failing.apply(preview)
    end.to raise_error(Woods::AgentConfiguration::Conflict, /Concurrent edit prevents recovery/)
    expect(File.read(layout.config_path)).to eq('{"client_changed":true}')
    expect(File).to exist("#{layout.receipt_path}.pending")
    expect { applier.apply(preview) }.to raise_error(Woods::AgentConfiguration::Conflict, /explicit recovery/)
    # A user resolves the concurrent file to one recorded state, then recovery
    # restores the other files without guessing at the competing edit.
    File.unlink(layout.config_path)
    expect(applier.recover).to eq('recovered')
    expect(File).not_to exist(layout.instruction_path('CLAUDE.md'))
    expect(File).not_to exist("#{layout.receipt_path}.pending")
  end
  it 'refuses an oversized recovery journal before changing any managed file' do
    original = 'a' * (3 * 1024 * 1024)
    File.write(layout.instruction_path('CLAUDE.md'), original)
    preview = plan
    expect(preview.to_json.bytesize).to be < Woods::AgentConfiguration::Document::MAX_BYTES
    expect { applier.apply(preview) }.to raise_error(Woods::AgentConfiguration::Conflict, /journal would exceed/)
    expect(File.read(layout.instruction_path('CLAUDE.md'))).to eq(original)
    expect(File).not_to exist(layout.config_path)
    expect(File).not_to exist("#{layout.receipt_path}.pending")
  end

  it 'reports malformed recovery plan shapes and retains the journal unchanged' do
    path = "#{layout.receipt_path}.pending"
    original = JSON.generate('plan' => nil, 'originals' => [])
    File.write(path, original)
    expect { applier.recover }.to raise_error(Woods::AgentConfiguration::Conflict, /Plan format/)
    expect(File.read(path)).to eq(original)
  end
end
