# frozen_string_literal: true

require 'shellwords'

require_relative 'ablation_worktree'
require_relative 'ablation_summary'
require_relative 'ablation_provenance'
require_relative 'ablation_agent_payload'
require_relative 'ablation_executor'
require_relative 'ablation_timed_executor'

module Woods
  module Evaluation
    # Runs every task in an {AblationTaskSet} twice, index on and index off,
    # each trial in its own disposable {AblationWorktree} checked out from a
    # fixed baseline commit, and reports resolution rate, tokens, cost,
    # turns, and errors per condition (#280).
    #
    # This is a harness for collecting paired on/off runs, not a source of
    # causal evidence: sample size, task selection, and agent nondeterminism
    # all bear on what a result means. See docs/EVALUATION.md.
    #
    # The agent is any command that prints one JSON object on stdout in the
    # `claude -p --output-format json` shape. The executor is injectable so
    # the runner never invokes a real agent in specs.
    #
    # Every command a trial runs (worktree add/remove, the optional reset,
    # the agent invocation, and the check) shares one {AblationTimedExecutor}
    # and is therefore bound by the same `timeout`, applied per call rather
    # than once for the whole trial: a slow reset does not eat into the
    # agent's budget, and vice versa. A timed-out call is terminated (TERM,
    # then KILL if still alive after a short grace period) when the
    # underlying executor exposes a pid.
    #
    # @example
    #   set = AblationTaskSet.load('config/eval_ablation.json')
    #   report = AblationRunner.new(task_set: set, workdir: Rails.root.to_s).run
    #   report.summary[:delta][:mean_tokens] # => negative when the index saves tokens
    #
    class AblationRunner
      Result = Struct.new(:task_id, :condition, :resolved, :total_tokens, :cost_usd, :turns, :duration_ms,
                          :error, :provenance, keyword_init: true)
      Report = Struct.new(:results, :summary, keyword_init: true)

      DEFAULT_TIMEOUT = 600

      # Verifies Woods availability before a trial runs, distinguishing "MCP
      # enabled" (the agent command is wired to reach the Woods MCP server)
      # from "index present" (an index actually exists in the checkout): the
      # `:on` condition needs both, the `:off` condition needs to confirm
      # MCP is truly unreachable.
      DEFAULT_WOODS_PROBE = lambda do |condition, chdir, command|
        mcp_wired = command.include?('--mcp-config')
        strict = command.include?('--strict-mcp-config')
        index_present = File.exist?(File.join(chdir, 'tmp', 'woods', 'generation.json'))
        if condition == :on
          mcp_wired && index_present
        else
          strict || !mcp_wired
        end
      end

      # @param task_set [AblationTaskSet::Definition]
      # @param workdir [String] the host application root
      # @param executor [#call] `call(command, chdir:)` returning `[stdout, stderr, success]`.
      #   Wrapped in an {AblationTimedExecutor} exactly once, so every command a trial runs
      #   through it (worktree add/remove, reset, agent, check) shares the same per-call
      #   timeout; see `timeout` below.
      # @param conditions [Array<Symbol>] subset of `%i[on off]`
      # @param trial_options [Hash]
      # @option trial_options [Numeric] :timeout seconds allowed per call the trial makes
      #   (worktree add/remove, the optional reset, the agent invocation, and the check),
      #   applied independently to each one rather than shared across the whole trial
      # @option trial_options [#call] :woods_probe `call(condition, chdir, command)` returning a boolean
      def initialize(task_set:, workdir:, executor: nil, conditions: %i[on off], **trial_options)
        @task_set = task_set
        @workdir = workdir
        @conditions = conditions
        @timeout = trial_options.fetch(:timeout, DEFAULT_TIMEOUT)
        @woods_probe = trial_options.fetch(:woods_probe, DEFAULT_WOODS_PROBE)
        @executor = AblationTimedExecutor.new(executor || AblationExecutor.new, timeout: @timeout)
      end

      # @return [Report]
      def run
        baseline_sha = resolve_baseline_sha
        results = @task_set.tasks.flat_map do |task|
          @conditions.map { |condition| run_trial(task, condition, baseline_sha) }
        end
        Report.new(results: results, summary: AblationSummary.build(results, @conditions))
      end

      private

      def resolve_baseline_sha
        out, _err, ok = @executor.call('git rev-parse HEAD', chdir: @workdir)
        ok ? out.strip : nil
      end

      def run_trial(task, condition, baseline_sha)
        worktree = AblationWorktree.new(repo_root: @workdir, baseline_sha: baseline_sha, executor: @executor)
        result = nil
        setup_error = worktree.trial(@task_set.reset) { |path| result = execute(task, condition, path, baseline_sha) }
        result || failed_result(task, condition, blank_provenance(condition, baseline_sha), setup_error)
      end

      def execute(task, condition, path, baseline_sha)
        chdir = File.expand_path(task.workdir, path)
        command = agent_command(condition).sub('{prompt}', Shellwords.escape(task.prompt))
        provenance = AblationProvenance.build(agent_command: command, chdir: chdir, baseline_sha: baseline_sha)

        probe_error = preflight_error(condition, chdir, command)
        return failed_result(task, condition, provenance, probe_error) if probe_error

        run_agent_and_check(task, condition, chdir, command, provenance)
      end

      def run_agent_and_check(task, condition, chdir, command, provenance)
        stdout, stderr, success = @executor.call(command, chdir: chdir)
        payload = AblationAgentPayload.parse(stdout)
        provenance.model = payload && payload['model']
        _check_stdout, check_stderr, resolved = @executor.call(task.check, chdir: chdir)

        Result.new(task_id: task.id, condition: condition, resolved: resolved == true,
                   total_tokens: payload && AblationAgentPayload.token_total(payload['usage']),
                   cost_usd: payload && payload['total_cost_usd'],
                   turns: payload && payload['num_turns'],
                   duration_ms: payload && payload['duration_ms'],
                   error: agent_error(success, payload, stderr) || check_timeout_error(check_stderr),
                   provenance: provenance)
      end

      def agent_error(success, payload, stderr)
        return nil if success && payload

        [stderr.to_s.strip, payload ? nil : 'agent printed no JSON'].compact.join('; ')
      end

      # The check's own exit status already drives `resolved`; a normal test
      # failure is not a harness error. A timeout is: {AblationTimedExecutor}
      # marks it with a recognizable stderr message, so it still surfaces as
      # an error (and is counted in the summary) even though `resolved` is
      # also false.
      def check_timeout_error(check_stderr)
        return nil unless check_stderr.to_s.include?('timed out after')

        "check #{check_stderr.strip}"
      end

      def preflight_error(condition, chdir, command)
        return nil if @woods_probe.call(condition, chdir, command)

        "Woods availability check failed for condition #{condition}"
      end

      def failed_result(task, condition, provenance, error)
        Result.new(task_id: task.id, condition: condition, resolved: false, total_tokens: nil, cost_usd: nil,
                   turns: nil, duration_ms: nil, error: error, provenance: provenance)
      end

      def blank_provenance(condition, baseline_sha)
        AblationProvenance.new(agent_command: agent_command(condition), model: nil, config: nil,
                               woods_generation: nil, baseline_sha: baseline_sha)
      end

      def agent_command(condition)
        condition == :on ? @task_set.agent_on : @task_set.agent_off
      end
    end
  end
end
