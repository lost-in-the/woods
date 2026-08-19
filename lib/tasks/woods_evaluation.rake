# frozen_string_literal: true

# lib/tasks/woods_evaluation.rake
#
# Rake tasks for evaluating retrieval quality.
#
# Usage:
#   bundle exec rake woods:evaluate                # Run evaluation
#   bundle exec rake "woods:evaluate:baseline[grep]"  # Run baseline comparison
#
# Loaded by the railtie alongside woods.rake. It previously was not loaded at
# all, so neither task existed on any host — and the code below called
# `Woods.vector_store` / `Woods.metadata_store` / `Woods.graph_store` /
# `Woods.embedding_provider`, none of which have ever existed. Both halves are
# fixed together (#212): stores now come from the MCP bootstrapper, the same
# path that hydrates persisted vector/metadata/graph artifacts for retrieval.
#
# Offline runs need no API key — set `embedding_provider = :fake` (#178).

namespace :woods do
  desc 'Run evaluation queries against the retrieval pipeline'
  task evaluate: :environment do
    Woods::EvaluationTasks.run_evaluation
  end

  namespace :evaluate do
    desc 'Run baseline comparison (strategy: grep, random, or file_level)'
    task :baseline, [:strategy] => :environment do |_t, args|
      Woods::EvaluationTasks.run_baseline(strategy: args[:strategy])
    end
  end
end

module Woods
  # Bodies of the `woods:evaluate` rake tasks.
  #
  # A module rather than top-level `def`s: a rake file's bare methods land on
  # Object and become callable on every object in the host application.
  module EvaluationTasks
    DEFAULT_QUERY_SET = 'config/eval_queries.json'
    DEFAULT_OUTPUT = 'tmp/eval_report.json'
    DEFAULT_BUDGET = 8000
    DEFAULT_BASELINE_LIMIT = 10

    module_function

    # Evaluate the real retrieval pipeline against a ground-truth query set.
    #
    # @return [void]
    def run_evaluation
      require 'woods/mcp/bootstrapper'
      require 'woods/evaluation/query_set'
      require 'woods/evaluation/evaluator'
      require 'woods/evaluation/report_generator'

      query_set_path = ENV.fetch('EVAL_QUERY_SET', DEFAULT_QUERY_SET)
      output_path = ENV.fetch('EVAL_OUTPUT', DEFAULT_OUTPUT)
      budget = ENV.fetch('EVAL_BUDGET', DEFAULT_BUDGET.to_s).to_i

      puts "Loading query set from: #{query_set_path}"
      query_set = Evaluation::QuerySet.load(query_set_path)
      puts "Loaded #{query_set.size} queries — building retriever..."

      report = Evaluation::Evaluator.new(
        retriever: build_eval_retriever, query_set: query_set, budget: budget
      ).evaluate

      Evaluation::ReportGenerator.new
                                 .save(report, output_path, metadata: { 'query_set' => query_set_path })

      print_eval_report(report, output_path)
    end

    # Score a naive baseline strategy on the same query set, for comparison.
    #
    # @param strategy [String, nil] grep, random, or file_level
    # @return [void]
    def run_baseline(strategy: nil)
      require 'woods/mcp/bootstrapper'
      require 'woods/evaluation/query_set'
      require 'woods/evaluation/baseline_runner'
      require 'woods/evaluation/metrics'

      strategy = (strategy || ENV.fetch('EVAL_BASELINE_STRATEGY', 'grep')).to_sym
      query_set_path = ENV.fetch('EVAL_QUERY_SET', DEFAULT_QUERY_SET)
      limit = ENV.fetch('EVAL_BASELINE_LIMIT', DEFAULT_BASELINE_LIMIT.to_s).to_i

      puts "Loading query set from: #{query_set_path}"
      query_set = Evaluation::QuerySet.load(query_set_path)
      puts "Running #{strategy} baseline (limit: #{limit})..."

      runner = Evaluation::BaselineRunner.new(metadata_store: build_eval_retriever.metadata_store)
      totals = compute_baseline_totals(query_set, runner, strategy, limit)

      print_baseline_report(strategy, query_set.size, totals)
    end

    # @return [Hash] Summed MRR and recall across the query set
    def compute_baseline_totals(query_set, runner, strategy, limit)
      query_set.queries.each_with_object({ mrr: 0.0, recall: 0.0 }) do |query, totals|
        results = runner.run(query.query, strategy: strategy, limit: limit)
        totals[:mrr] += Evaluation::Metrics.mrr(results, query.expected_units)
        totals[:recall] += Evaluation::Metrics.recall(results, query.expected_units)
      end
    end

    # The configured retrieval pipeline, hydrated from persisted artifacts the
    # same way the MCP server builds semantic search.
    #
    # @return [Woods::Retriever]
    def build_eval_retriever
      retriever, _state = MCP::Bootstrapper.build_retriever(index_dir: Woods.configuration.output_dir)
      retriever || raise(Woods::Error, 'Evaluation requires an embedded Woods index with a configured provider.')
    end

    def print_eval_report(report, output_path)
      puts
      puts 'Evaluation complete!'
      puts '=' * 50
      report.aggregates.each do |key, value|
        formatted = value.is_a?(Float) ? format('%.4f', value) : value.to_s
        puts "  #{key.to_s.ljust(25)}: #{formatted}"
      end
      puts '=' * 50
      puts "Report saved to: #{output_path}"
    end

    def print_baseline_report(strategy, count, totals)
      puts
      puts "Baseline: #{strategy}"
      puts '=' * 50
      puts "  Mean MRR:    #{format('%.4f', count.positive? ? totals[:mrr] / count : 0.0)}"
      puts "  Mean Recall: #{format('%.4f', count.positive? ? totals[:recall] / count : 0.0)}"
      puts '=' * 50
    end
  end
end
