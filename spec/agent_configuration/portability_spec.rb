# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'woods/agent_configuration/layout'
require 'woods/agent_configuration/planner'
require 'woods/agent_configuration/applier'

RSpec.describe 'Agent configuration ownership across host environments' do
  around do |example|
    Dir.mktmpdir('woods project ownership ') do |directory|
      @directory = File.realpath(directory)
      @root = File.join(@directory, 'application')
      FileUtils.mkdir_p(@root)
      example.run
    end
  end

  let(:entry) { { 'command' => 'bundle', 'args' => ['exec', 'woods-mcp-start', File.join(@root, 'tmp/woods')] } }

  def layout(home, scope: 'project')
    Woods::AgentConfiguration::Layout.new(root: @root, scope: scope, home: File.join(@directory, home),
                                          config_dir: File.join(@directory, home, 'custom-client'))
  end

  def plan(selected, operation = 'setup', **options)
    Woods::AgentConfiguration::Planner.new(layout: selected, operation: operation, entry: entry,
                                           instructions: ['CLAUDE.md'], **options).call
  end

  def apply(selected, preview)
    Woods::AgentConfiguration::Applier.new(layout: selected).apply(preview)
  end

  it 'keeps new project plans and receipts independent of user configuration directories' do
    first = layout('first-home')
    second = layout('second-home')
    preview = plan(first)
    expect(preview.data.fetch('layout')).not_to have_key('config_dir')
    expect(apply(second, preview)).to eq('applied')
    expect(plan(second).data.fetch('changes')).to be_empty
    expect(apply(second, plan(second, 'remove'))).to eq('applied')
    expect(File).not_to exist(first.config_path)
  end

  it 'accepts only the irrelevant config_dir difference in legacy project plans and receipts' do
    first = layout('first-home')
    second = layout('second-home')
    preview = plan(first)
    preview.data.fetch('layout')['config_dir'] = first.config_dir
    path = File.join(@directory, 'legacy-plan.json')
    File.write(path, preview.to_json)
    expect(apply(second, Woods::AgentConfiguration::Plan.load(path))).to eq('applied')

    receipt = JSON.parse(File.read(first.receipt_path))
    receipt.fetch('layout')['config_dir'] = first.config_dir
    File.write(first.receipt_path, JSON.generate(receipt))
    expect(plan(second).data.fetch('changes')).to be_empty
    updated = entry.merge('args' => ['exec', 'woods-mcp-start', File.join(@root, 'tmp/other')])
    apply(second, plan(second, 'update', entry: updated))
    expect(JSON.parse(File.read(first.receipt_path)).fetch('layout')).not_to have_key('config_dir')
    apply(second, plan(second, 'remove'))
    expect(File).not_to exist(first.config_path)
  end

  it 'still refuses a legacy plan after a target changes across user homes' do
    preview = plan(layout('first-home'))
    preview.data.fetch('layout')['config_dir'] = '/legacy/home/.claude'
    File.write(layout('second-home').config_path, '{"user_changed":true}')
    expect { apply(layout('second-home'), preview) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Changed since preview/)
    expect(File.read(layout('second-home').config_path)).to eq('{"user_changed":true}')
  end

  %w[client scope root config_path receipt_path unexpected].each do |field|
    it "retains exact legacy project identity matching for #{field}" do
      first = layout('first-home')
      preview = plan(first)
      preview.data.fetch('layout')['config_dir'] = '/legacy/home/.claude'
      preview.data.fetch('layout')[field] = 'different'
      expect { apply(layout('second-home'), preview) }
        .to raise_error(Woods::AgentConfiguration::Conflict, /identity fields: #{field}/)
      expect(File).not_to exist(first.config_path)
    end

    it "refuses a legacy project receipt with a different #{field} before writing" do
      first = layout('first-home')
      apply(first, plan(first))
      receipt = JSON.parse(File.read(first.receipt_path))
      receipt.fetch('layout')['config_dir'] = '/legacy/home/.claude'
      receipt.fetch('layout')[field] = 'different'
      original = JSON.generate(receipt)
      File.write(first.receipt_path, original)
      expect { plan(layout('second-home'), 'remove') }
        .to raise_error(Woods::AgentConfiguration::Conflict, /identity fields: #{field}/)
      expect(File.read(first.receipt_path)).to eq(original)
      expect(File).to exist(first.config_path)
    end
  end

  it 'keeps user-scoped plans tied to the selected user configuration directory' do
    first = layout('first-home', scope: 'user')
    second = layout('second-home', scope: 'user')
    expect { apply(second, plan(first)) }
      .to raise_error(Woods::AgentConfiguration::Conflict, /Plan format/)
    expect(File).not_to exist(first.config_path)
    expect(File).not_to exist(second.config_path)
  end
end
