# frozen_string_literal: true

require_relative 'ablation_task_set'
require_relative 'ablation_runner'
require_relative 'ablation_report_writer'

module Woods
  module Evaluation
    # Entry point for `woods:evaluate:ablation`: loads a task set, applies
    # environment overrides, runs the harness, and writes the report (#280).
    # Kept out of the rake file so the task definition stays a thin
    # delegation and the logic is testable without Rake.
    class AblationTask
      DEFAULT_TASKS = 'config/eval_ablation.json'
      DEFAULT_OUTPUT = 'tmp/eval_ablation.json'

      # @param task_set_path [String, nil]
      # @param workdir [String]
      # @return [AblationRunner::Report]
      def self.run(task_set_path: nil, workdir: Dir.pwd)
        new(task_set_path: task_set_path, workdir: workdir).run
      end

      def initialize(task_set_path: nil, workdir: Dir.pwd)
        @task_set_path = task_set_path || ENV.fetch('EVAL_ABLATION_TASKS', DEFAULT_TASKS)
        @output = ENV.fetch('EVAL_ABLATION_OUTPUT', DEFAULT_OUTPUT)
        @workdir = workdir
      end

      # @return [AblationRunner::Report]
      def run
        task_set = load_task_set
        puts "Running #{task_set.tasks.size} task(s) with the index on and off, " \
             'one disposable worktree per trial...'
        report = AblationRunner.new(task_set: task_set, workdir: @workdir).run

        writer = AblationReportWriter.new(report)
        writer.write(@output)
        puts writer.summary_text
        puts "Report saved to: #{@output}"
        report
      end

      private

      def load_task_set
        task_set = AblationTaskSet.load(@task_set_path)
        task_set.agent_on = ENV['EVAL_AGENT_ON'] if ENV['EVAL_AGENT_ON']
        task_set.agent_off = ENV['EVAL_AGENT_OFF'] if ENV['EVAL_AGENT_OFF']
        task_set
      end
    end
  end
end
