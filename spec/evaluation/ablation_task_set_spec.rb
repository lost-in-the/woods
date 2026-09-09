# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'json'
require 'woods'
require 'woods/evaluation/ablation_task_set'

RSpec.describe Woods::Evaluation::AblationTaskSet do
  let(:fixture) { File.expand_path('../fixtures/evaluation_ablation_tasks.example.json', __dir__) }

  it 'loads the commands, reset, and tasks from the fixture' do
    set = described_class.load(fixture)

    expect(set.schema_version).to eq(1)
    expect(set.agent_on).to include('--mcp-config')
    expect(set.agent_off).to include('--strict-mcp-config')
    expect(set.reset).to eq('git checkout -- . && git clean -fdq')
    expect(set.tasks.map(&:id)).to eq(%w[comment-count publish-job])
    expect(set.tasks.last.workdir).to eq('.')
    expect(set.tasks.first.workdir).to eq('.')
  end

  it 'rejects an unsupported schema version and a task without id, prompt, or check' do
    Dir.mktmpdir do |dir|
      bad_version = File.join(dir, 'v.json')
      File.write(bad_version, JSON.generate('schema_version' => 2, 'tasks' => []))
      expect { described_class.load(bad_version) }.to raise_error(Woods::Error, /schema_version/)

      bad_task = File.join(dir, 't.json')
      File.write(bad_task, JSON.generate('schema_version' => 1, 'agent_on' => 'a {prompt}', 'agent_off' => 'b {prompt}',
                                         'tasks' => [{ 'id' => 'x', 'prompt' => 'p' }]))
      expect { described_class.load(bad_task) }.to raise_error(Woods::Error, /check/)
    end
  end

  it 'requires both agent commands to mention {prompt}' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'p.json')
      File.write(path, JSON.generate('schema_version' => 1, 'agent_on' => 'claude', 'agent_off' => 'claude {prompt}',
                                     'tasks' => []))
      expect { described_class.load(path) }.to raise_error(Woods::Error, /agent_on.*\{prompt\}/)
    end
  end
end
