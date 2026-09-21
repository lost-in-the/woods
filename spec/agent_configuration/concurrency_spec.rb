# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'timeout'
require 'woods/agent_configuration/layout'
require 'woods/agent_configuration/planner'
require 'woods/agent_configuration/applier'

RSpec.describe 'Shared agent configuration coordination' do
  let(:directory) { Dir.mktmpdir('woods-shared-config') }
  let(:home) { File.join(directory, 'home') }
  let(:layouts) do
    %w[first second].map do |name|
      root = File.join(directory, name)
      FileUtils.mkdir_p(root)
      Woods::AgentConfiguration::Layout.new(root: root, home: home, scope: 'user', config_dir: nil)
    end
  end

  after { FileUtils.remove_entry(directory) }

  def plan(layout, name, instructions: [])
    Woods::AgentConfiguration::Planner.new(layout: layout, operation: 'setup', name: name,
                                           entry: { 'command' => 'bundle', 'args' => %w[exec woods-mcp-start] },
                                           instructions: instructions).call
  end

  def paused_writer(layout, target: layout.config_path)
    ready = Queue.new
    resume = Queue.new
    writer = lambda do |path, content, **options|
      if path == target
        ready << true
        resume.pop
      end
      Woods::AtomicFile.write(path, content, **options)
    end
    worker = Thread.new { yield(:worker, writer) }
    Timeout.timeout(5) { ready.pop }
    yield(:contender, nil)
  ensure
    resume << true
    worker&.join(5) || worker&.kill
    worker&.value
  end

  it 'refuses competing application writes, then requires a fresh plan preserving both installations' do
    first, second = layouts
    first_plan = plan(first, 'woods_first')
    second_plan = plan(second, 'woods_second')
    expect(first.receipt_path).not_to eq(second.receipt_path)
    paused_writer(first) do |role, writer|
      if role == :worker
        Woods::AgentConfiguration::Applier.new(layout: first, writer: writer).apply(first_plan)
      else
        expect { Woods::AgentConfiguration::Applier.new(layout: second).apply(second_plan) }
          .to raise_error(Woods::AgentConfiguration::Conflict, /operation is active/)
        expect(File).not_to exist(second.receipt_path)
      end
    end
    expect(JSON.parse(File.read(first.config_path)).fetch('mcpServers').keys).to eq(['woods_first'])
    expect { Woods::AgentConfiguration::Applier.new(layout: second).apply(second_plan) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Changed since preview/)
    Woods::AgentConfiguration::Applier.new(layout: second).apply(plan(second, 'woods_second'))
    expect(JSON.parse(File.read(first.config_path)).fetch('mcpServers').keys)
      .to contain_exactly('woods_first', 'woods_second')
    expect(layouts.map { |layout| File.file?(layout.receipt_path) }).to eq([true, true])
  end

  it 'coordinates shared instructions even when the configuration JSON paths differ' do
    first, original_second = layouts
    second = Woods::AgentConfiguration::Layout.new(root: original_second.root, home: home, scope: 'user',
                                                   config_dir: File.join(home, '.claude'))
    target = first.instruction_path('CLAUDE.md')
    expect(second.config_path).not_to eq(first.config_path)
    expect(second.instruction_path('CLAUDE.md')).to eq(target)
    first_plan = plan(first, 'woods_first', instructions: ['CLAUDE.md'])
    second_plan = plan(second, 'woods_second', instructions: ['CLAUDE.md'])
    paused_writer(first, target: target) do |role, writer|
      if role == :worker
        Woods::AgentConfiguration::Applier.new(layout: first, writer: writer).apply(first_plan)
      else
        expect { Woods::AgentConfiguration::Applier.new(layout: second).apply(second_plan) }
          .to raise_error(Woods::AgentConfiguration::Conflict, /operation is active/)
      end
    end
    expect(File).not_to exist(second.receipt_path)
    expect(File).not_to exist(second.config_path)
  end

  it 'rejects a shared lock symlink without touching its target or managed files' do
    layout = layouts.first
    preview = plan(layout, 'woods_first')
    outside = File.join(directory, 'outside')
    File.write(outside, 'keep')
    FileUtils.mkdir_p(File.dirname(layout.config_path))
    File.symlink(outside, "#{layout.config_path}.woods.lock")
    expect { Woods::AgentConfiguration::Applier.new(layout: layout).apply(preview) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Symlink/)
    expect(File.read(outside)).to eq('keep')
    expect(File).not_to exist(layout.config_path)
    expect(File).not_to exist(layout.receipt_path)
  end

  it 'refuses recovery while another application is applying shared configuration' do
    first, second = layouts
    first_plan = plan(first, 'woods_first')
    paused_writer(first) do |role, writer|
      if role == :worker
        Woods::AgentConfiguration::Applier.new(layout: first, writer: writer).apply(first_plan)
      else
        expect { Woods::AgentConfiguration::Applier.new(layout: second).recover }
          .to raise_error(Woods::AgentConfiguration::Conflict, /operation is active/)
      end
    end
  end

  it 'holds the shared configuration lock while recovering an interrupted application' do
    first, second = layouts
    FileUtils.mkdir_p(home)
    File.write(first.config_path, '{}')
    first_plan = plan(first, 'woods_first')
    interrupting_writer = lambda do |path, content, **options|
      Woods::AtomicFile.write(path, content, **options)
      raise Interrupt, 'simulated interruption' if path == first.config_path
    end
    expect do
      Woods::AgentConfiguration::Applier.new(layout: first, writer: interrupting_writer).apply(first_plan)
    end.to raise_error(Interrupt, /simulated/)
    second_plan = plan(second, 'woods_second')
    paused_writer(first) do |role, writer|
      if role == :worker
        Woods::AgentConfiguration::Applier.new(layout: first, writer: writer).recover
      else
        expect { Woods::AgentConfiguration::Applier.new(layout: second).apply(second_plan) }
          .to raise_error(Woods::AgentConfiguration::Conflict, /operation is active/)
      end
    end
    expect(File.read(first.config_path)).to eq('{}')
    expect(File).not_to exist("#{first.receipt_path}.pending")
    expect(File).not_to exist(second.receipt_path)
  end
end
