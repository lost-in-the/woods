# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'json'
require 'woods'
require 'woods/evaluation/ablation_task_set'
require 'woods/evaluation/ablation_runner'

# The harness never invokes a real agent here: every executor below is a
# fake that only recognizes the fixed shell surface the runner touches (git
# baseline resolution, worktree add/remove, an optional reset, the agent,
# and the check) and answers with the `claude -p --output-format json`
# shape (#280).
RSpec.describe Woods::Evaluation::AblationRunner do
  let(:task_class) { Woods::Evaluation::AblationTaskSet::Task }
  let(:definition_class) { Woods::Evaluation::AblationTaskSet::Definition }

  let(:task_set) do
    definition_class.new(
      schema_version: 1,
      agent_on: 'agent --on {prompt} --mcp-config .mcp.json',
      agent_off: 'agent --off {prompt} --strict-mcp-config',
      reset: 'reset-tree',
      tasks: [
        task_class.new(id: 'a', prompt: 'do a', check: 'check-a', workdir: '.'),
        task_class.new(id: 'b', prompt: 'do "b"', check: 'check-b', workdir: 'sub')
      ]
    )
  end

  def agent_json(tokens_in:, tokens_out:, cost:, turns:)
    JSON.generate('type' => 'result', 'is_error' => false, 'num_turns' => turns, 'duration_ms' => 1000,
                  'total_cost_usd' => cost, 'model' => 'claude-x',
                  'usage' => { 'input_tokens' => tokens_in, 'output_tokens' => tokens_out,
                               'cache_creation_input_tokens' => 10, 'cache_read_input_tokens' => 5 })
  end

  # The default probe checks the real filesystem for a materialized index,
  # which none of these fake checkouts have. Tests that are not exercising
  # the probe itself opt out of it.
  let(:permissive_probe) { ->(*_args) { true } }

  def executor(agent_on_ok: true, check_results: { 'check-a' => true, 'check-b' => true })
    calls = []
    call = lambda do |command, chdir:|
      calls << [command, chdir]
      case command
      when 'git rev-parse HEAD' then ["abc123\n", '', true]
      when /\Agit worktree (add|remove)/, 'reset-tree' then ['', '', true]
      when /\Aagent --on/
        next ['not json', 'boom', false] unless agent_on_ok

        [agent_json(tokens_in: 100, tokens_out: 50, cost: 0.02, turns: 4), '', true]
      when /\Aagent --off/ then [agent_json(tokens_in: 300, tokens_out: 90, cost: 0.06, turns: 9), '', true]
      when /\Acheck-/ then ['', '', check_results.fetch(command)]
      else raise "unexpected command: #{command}"
      end
    end
    [call, calls]
  end

  it 'runs every trial in its own disposable worktree checked out at the resolved baseline SHA' do
    call, calls = executor
    described_class.new(task_set: task_set, workdir: '/app', executor: call, woods_probe: permissive_probe).run

    add_commands = calls.select { |command, _| command.start_with?('git worktree add') }
    remove_commands = calls.select { |command, _| command.start_with?('git worktree remove') }

    expect(add_commands.size).to eq(4) # 2 tasks x 2 conditions
    expect(remove_commands.size).to eq(4)
    expect(add_commands.map(&:last).uniq).to eq(['/app'])
    expect(remove_commands.map(&:last).uniq).to eq(['/app'])
    expect(add_commands).to all(satisfy { |command, _| command.end_with?('abc123') })

    trial_dirs = add_commands.map { |command, _| command[/add --detach (\S+) /, 1] }
    expect(trial_dirs.uniq.size).to eq(4)

    reset_dirs = calls.filter_map { |command, chdir| chdir if command == 'reset-tree' }
    expect(reset_dirs).to match_array(trial_dirs)

    task_a_dirs = trial_dirs.select { |dir| calls.any? { |c, chdir| c == 'check-a' && chdir == dir } }
    task_b_dirs = trial_dirs.select { |dir| calls.any? { |c, chdir| c == 'check-b' && chdir == File.join(dir, 'sub') } }
    expect(task_a_dirs.size).to eq(2)
    expect(task_b_dirs.size).to eq(2)
  end

  it 'records resolution, tokens, cost, turns, and provenance per trial' do
    call, = executor
    report = described_class.new(task_set: task_set, workdir: '/app', executor: call, woods_probe: permissive_probe).run

    on = report.results.find { |r| r.task_id == 'a' && r.condition == :on }
    off = report.results.find { |r| r.task_id == 'a' && r.condition == :off }

    expect(on.resolved).to be(true)
    expect(on.total_tokens).to eq(165)
    expect(on.cost_usd).to eq(0.02)
    expect(on.turns).to eq(4)
    expect(on.provenance.baseline_sha).to eq('abc123')
    expect(on.provenance.model).to eq('claude-x')
    expect(on.provenance.config).to eq('.mcp.json')
    expect(off.provenance.config).to eq('strict')
  end

  it 'summarizes both conditions with resolution rate, means, and an error count, plus the delta' do
    call, = executor
    report = described_class.new(task_set: task_set, workdir: '/app', executor: call, woods_probe: permissive_probe).run

    expect(report.summary[:on]).to eq(resolution_rate: 1.0, mean_tokens: 165.0, mean_cost_usd: 0.02,
                                      mean_turns: 4.0, tasks: 2, errors: 0)
    expect(report.summary[:off]).to eq(resolution_rate: 1.0, mean_tokens: 405.0, mean_cost_usd: 0.06,
                                       mean_turns: 9.0, tasks: 2, errors: 0)
    expect(report.summary[:delta]).to eq(resolution_rate: 0.0, mean_tokens: -240.0, mean_cost_usd: -0.04,
                                         mean_turns: -5.0)
  end

  it 'scores resolution from the check command and records failures without raising' do
    call, = executor(check_results: { 'check-a' => false, 'check-b' => true })
    report = described_class.new(task_set: task_set, workdir: '/app', executor: call, woods_probe: permissive_probe).run

    on_a = report.results.find { |r| r.task_id == 'a' && r.condition == :on }
    expect(on_a.resolved).to be(false)
    expect(report.summary[:on][:resolution_rate]).to eq(0.5)
  end

  it 'records an error and nil tokens when the agent prints no JSON, without raising' do
    call, = executor(agent_on_ok: false)
    report = described_class.new(task_set: task_set, workdir: '/app', executor: call, conditions: [:on],
                                 woods_probe: permissive_probe).run

    expect(report.results.map(&:total_tokens).uniq).to eq([nil])
    expect(report.results.first.error).to include('boom')
    expect(report.summary[:on][:mean_tokens]).to be_nil
    expect(report.summary[:on][:errors]).to eq(2)
    expect(report.summary).not_to have_key(:delta)
  end

  it 'aborts a trial as an error when the reset command fails, without running the agent or check' do
    calls = []
    broken_call = lambda do |command, chdir:|
      calls << command
      case command
      when 'git rev-parse HEAD' then ["abc123\n", '', true]
      when /\Agit worktree/ then ['', '', true]
      when 'reset-tree' then ['', "dirty tree in #{chdir}", false]
      else raise "unexpected command: #{command}"
      end
    end

    report = described_class.new(task_set: task_set, workdir: '/app', executor: broken_call,
                                 conditions: [:on]).run

    expect(report.results).to all(have_attributes(resolved: false, total_tokens: nil))
    expect(report.results.map(&:error)).to all(include('reset failed'))
    expect(calls).not_to include(a_string_starting_with('agent'))
  end

  it 'aborts a trial when the Woods availability probe rejects the condition' do
    call, = executor
    probe = ->(condition, _chdir, _command) { condition != :on }

    report = described_class.new(task_set: task_set, workdir: '/app', executor: call, conditions: [:on],
                                 woods_probe: probe).run

    expect(report.results).to all(have_attributes(resolved: false))
    expect(report.results.map(&:error)).to all(include('availability'))
  end

  it 'records a timeout error and does not hang when the agent exceeds the per-trial timeout' do
    slow_call = lambda do |command, chdir:|
      case command
      when 'git rev-parse HEAD' then ["abc123\n", '', true]
      when /\Agit worktree/, 'reset-tree' then ['', '', true]
      when /\Aagent --on/
        sleep 0.05
        ['{}', "ran in #{chdir}", true]
      when /\Acheck-/ then ['', '', false]
      else raise "unexpected command: #{command}"
      end
    end

    report = described_class.new(task_set: task_set, workdir: '/app', executor: slow_call, conditions: [:on],
                                 timeout: 0.01, woods_probe: permissive_probe).run

    expect(report.results).to all(have_attributes(resolved: false))
    expect(report.results.map(&:error)).to all(include('timed out'))
  end

  it 'aborts a trial as an error when the reset command hangs past the per-call timeout' do
    hanging_reset = lambda do |command, chdir:|
      case command
      when 'git rev-parse HEAD' then ["abc123\n", '', true]
      when /\Agit worktree/ then ['', '', true]
      when 'reset-tree'
        sleep 0.05
        ["done in #{chdir}", '', true]
      else raise "unexpected command: #{command}"
      end
    end

    report = described_class.new(task_set: task_set, workdir: '/app', executor: hanging_reset, conditions: [:on],
                                 timeout: 0.01, woods_probe: permissive_probe).run

    expect(report.results).to all(have_attributes(resolved: false, total_tokens: nil))
    expect(report.results.map(&:error)).to all(include('reset failed', 'timed out'))
  end

  it 'aborts a trial as an error when the check command hangs past the per-call timeout' do
    hanging_check = lambda do |command, chdir:|
      case command
      when 'git rev-parse HEAD' then ["abc123\n", '', true]
      when /\Agit worktree/, 'reset-tree' then ['', '', true]
      when /\Aagent --on/ then [agent_json(tokens_in: 100, tokens_out: 50, cost: 0.02, turns: 4), '', true]
      when /\Acheck-/
        sleep 0.05
        ["done in #{chdir}", '', true]
      else raise "unexpected command: #{command}"
      end
    end

    report = described_class.new(task_set: task_set, workdir: '/app', executor: hanging_check, conditions: [:on],
                                 timeout: 0.01, woods_probe: permissive_probe).run

    expect(report.results).to all(have_attributes(resolved: false))
    expect(report.results.map(&:error)).to all(include('check', 'timed out'))
    expect(report.summary[:on][:errors]).to eq(2)
  end

  describe 'the default Woods availability probe' do
    it 'requires both an --mcp-config reference and a materialized index for :on' do
      Dir.mktmpdir do |dir|
        probe = described_class::DEFAULT_WOODS_PROBE

        expect(probe.call(:on, dir, 'agent --mcp-config .mcp.json')).to be(false)

        FileUtils.mkdir_p(File.join(dir, 'tmp', 'woods'))
        File.write(File.join(dir, 'tmp', 'woods', 'generation.json'), '{}')

        expect(probe.call(:on, dir, 'agent --mcp-config .mcp.json')).to be(true)
        expect(probe.call(:on, dir, 'agent --strict-mcp-config')).to be(false)
      end
    end

    it 'requires the strict flag or no mcp-config reference for :off' do
      probe = described_class::DEFAULT_WOODS_PROBE

      expect(probe.call(:off, '/tmp', 'agent --strict-mcp-config')).to be(true)
      expect(probe.call(:off, '/tmp', 'agent')).to be(true)
      expect(probe.call(:off, '/tmp', 'agent --mcp-config .mcp.json')).to be(false)
    end
  end
end
