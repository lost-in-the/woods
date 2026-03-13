# frozen_string_literal: true

# lib/tasks/woods_evaluation.rake
#
# Rake tasks for evaluating retrieval quality.
#
# Usage:
#   bundle exec rake woods:evaluate                          # Run evaluation
#   bundle exec rake woods:evaluate:baseline[grep]           # Run baseline comparison

namespace :woods do
  desc 'Run evaluation queries against the retrieval pipeline'
  task evaluate: :environment do
    require 'woods/retriever'
    require 'woods/evaluation/query_set'
    require 'woods/evaluation/evaluator'
    require 'woods/evaluation/report_generator'

    run_evaluation
  end

  namespace :evaluate do
    desc 'Run baseline comparison'
    task :baseline, [:strategy] => :environment do |_t, args|
      require 'woods/evaluation/query_set'
      require 'woods/evaluation/baseline_runner'
      require 'woods/evaluation/metrics'

      run_baseline(args)
    end
  end
end

def run_evaluation
  query_set_path = ENV.fetch('EVAL_QUERY_SET', 'config/eval_queries.json')
  output_path = ENV.fetch('EVAL_OUTPUT', 'tmp/eval_report.json')
  budget = ENV.fetch('EVAL_BUDGET', '8000').to_i

  puts "Loading query set from: #{query_set_path}"
  query_set = Woods::Evaluation::QuerySet.load(query_set_path)
  puts "Loaded #{query_set.size} queries — building retriever..."

  evaluator = Woods::Evaluation::Evaluator.new(
    retriever: build_eval_retriever, query_set: query_set, budget: budget
  )
  report = evaluator.evaluate

  Woods::Evaluation::ReportGenerator.new
                                    .save(report, output_path, metadata: { 'query_set' => query_set_path })

  print_eval_report(report, output_path)
end

def run_baseline(args)
  strategy = (args[:strategy] || ENV.fetch('EVAL_BASELINE_STRATEGY', 'grep')).to_sym
  query_set_path = ENV.fetch('EVAL_QUERY_SET', 'config/eval_queries.json')
  limit = ENV.fetch('EVAL_BASELINE_LIMIT', '10').to_i

  puts "Loading query set from: #{query_set_path}"
  query_set = Woods::Evaluation::QuerySet.load(query_set_path)
  puts "Running #{strategy} baseline (limit: #{limit})..."

  runner = Woods::Evaluation::BaselineRunner.new(
    metadata_store: Woods.metadata_store
  )

  totals = compute_baseline_totals(query_set, runner, strategy, limit)
  print_baseline_report(strategy, query_set.size, totals)
end

def compute_baseline_totals(query_set, runner, strategy, limit)
  total_mrr = 0.0
  total_recall = 0.0

  query_set.queries.each do |query|
    results = runner.run(query.query, strategy: strategy, limit: limit)
    total_mrr += Woods::Evaluation::Metrics.mrr(results, query.expected_units)
    total_recall += Woods::Evaluation::Metrics.recall(results, query.expected_units)
  end

  { mrr: total_mrr, recall: total_recall }
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

# Build a retriever for evaluation (requires Rails environment with stores configured).
#
# @return [Woods::Retriever]
def build_eval_retriever
  Woods::Retriever.new(
    vector_store: Woods.vector_store,
    metadata_store: Woods.metadata_store,
    graph_store: Woods.graph_store,
    embedding_provider: Woods.embedding_provider
  )
end
