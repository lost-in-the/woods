# frozen_string_literal: true

# Paired #227 replay. These are actual published Canopy paths, not package
# ownership labels. Queries/gold/budgets/vectors remain unchanged. Explicit
# domain words choose fixed caller-intent paths before looking at outcomes.
require_relative 'runner'

module ScopeComparison
  DOMAINS = {
    'billing' => /billing|payment|refund/i,
    'newsletter' => /newsletter/i,
    'support' => /support/i
  }.freeze

  def self.paths_for(query)
    domain = DOMAINS.find { |_name, pattern| pattern.match?(query) }&.first
    return [] unless domain

    %w[controllers jobs models use_cases].map { |layer| "app/#{layer}/#{domain}" }
  end

  class Condition
    attr_reader :last_result

    def initialize(retriever, scoped:)
      @retriever = retriever
      @scoped = scoped
    end

    def retrieve(query, **options)
      paths = ScopeComparison.paths_for(query)
      options[:source_paths] = paths if @scoped && !paths.empty?
      @last_result = @retriever.retrieve(query, **options)
    end
  end

  def self.run
    runner = RetrievalBaseline::Runner.new
    capture = runner.read('vectors.json')
    runner.verify_capture!(capture)
    stores = runner.stores(capture.fetch('vectors'))
    results = %i[semantic lexical].flat_map do |mode|
      [false, true].flat_map do |scoped|
        retriever = Woods::Retriever.new(**stores.merge(mode: mode))
        condition = Condition.new(retriever, scoped: scoped)
        runner.corpus.fetch('queries').map do |query|
          row = runner.measure(condition, query)
          row.merge(condition: "#{mode}_#{scoped ? 'scoped' : 'unscoped'}", budget: query.fetch('budget'),
                    requested_source_paths: scoped ? paths_for(query.fetch('query')) : [],
                    applied_scope: condition.last_result.applied_scope)
        end
      end
    end
    { schema_version: 1, corpus_sha256: runner.digest('corpus.json'), vectors_sha256: runner.digest('vectors.json'),
      ruby: RUBY_VERSION, selection: DOMAINS.transform_values(&:source),
      scope: 'Existing Canopy source paths; no package ownership claims. Same 28 queries, gold labels and budgets. ' \
             'Domain-named questions use fixed cross-layer directory scopes; others are unscoped controls. ' \
             'Expected cross-boundary units remain in gold, so restricted scope can reduce recall. ' \
             'Warm captured-vector replay includes per-query scope preparation, excludes provider/network latency; no task outcomes.',
      results: results }
  end
end

if $PROGRAM_NAME == __FILE__
  report = ScopeComparison.run
  File.write(ARGV.fetch(0), JSON.pretty_generate(report) + "\n")
  runner = RetrievalBaseline::Runner.new
  report[:results].group_by { |row| row[:condition] }.each do |name, rows|
    puts JSON.generate(condition: name, **runner.aggregate(rows))
  end
end
