# frozen_string_literal: true

require_relative 'runner'
require 'woods/evaluation/baseline_runner'

module RetrievalComparison

# Evaluation-only personalized random walk. Fixed weights/iterations are declared
# before looking at labels; it never becomes the production default here.
class SeededExecutor
  def initialize(lexical, metadata, graph)
    @lexical, @metadata, @graph = lexical, metadata, graph
  end

  def execute(query:, type_filter: nil, exclude_types: nil, limit: 20)
    keys = @metadata.all_identifiers.sort.select do |key|
      type = @metadata.find(key).fetch('type').to_s
      type_filter && !type_filter.empty? ? type_filter.map(&:to_s).include?(type) : !Array(exclude_types).include?(type)
    end
    lexical = @lexical.execute(query: query, type_filter: type_filter, exclude_types: exclude_types, limit: keys.size)
    return lexical if lexical.candidates.empty?
    by_id = lexical.candidates.to_h { |candidate| [candidate.identifier, candidate] }
    total = by_id.values.sum(&:score)
    seeds = keys.to_h { |key| [key, by_id[key] ? by_id[key].score / total : 0.0] }
    rank = seeds.dup
    eligible = keys.to_set
    adjacent = keys.to_h do |key|
      links = (@graph.dependencies_of(key) + @graph.dependents_of(key)).uniq.select { |id| eligible.include?(id) }.sort
      [key, links]
    end
    20.times do
      updated = seeds.transform_values { |value| 0.15 * value }
      rank.each do |key, mass|
        links = adjacent.fetch(key)
        if links.empty?
          seeds.each { |target, restart| updated[target] += 0.85 * mass * restart }
        else
          links.each { |target| updated[target] += 0.85 * mass / links.size }
        end
      end
      rank = updated
    end
    candidates = keys.filter_map do |key|
      next unless rank[key].positive?
      unit = @metadata.find(key)
      Woods::Retrieval::SearchExecutor::Candidate.new(identifier: key, score: rank[key], source: :lexical,
        metadata: unit, matched_fields: (by_id[key]&.matched_fields || []) + ['graph:query_seeded'])
    end.sort_by { |c| [c.metadata['identifier'].to_s.casecmp?(query.strip) ? 0 : 1, -c.score, c.identifier] }
    Woods::Retrieval::SearchExecutor::ExecutionResult.new(candidates: candidates.first(limit), strategy: :lexical, query: query)
  end
end
# Existing identifier-substring baseline, with eligibility applied before its
# limit and the same lexical renderer/budget. It is not source-code grep.
class GrepExecutor
  def initialize(metadata)
    @metadata = metadata
  end

  def execute(query:, type_filter: nil, exclude_types: nil, limit: 20)
    eligible = Woods::Storage::MetadataStore::InMemory.new
    @metadata.all_identifiers.each do |key|
      unit = @metadata.find(key)
      type = unit.fetch('type').to_s
      next if type_filter && !type_filter.empty? && !type_filter.map(&:to_s).include?(type)
      next if (!type_filter || type_filter.empty?) && Array(exclude_types).map(&:to_s).include?(type)
      eligible.store(key, unit)
    end
    ids = Woods::Evaluation::BaselineRunner.new(metadata_store: eligible).run(query, strategy: :grep, limit: limit)
    candidates = ids.map do |id|
      Woods::Retrieval::SearchExecutor::Candidate.new(identifier: id, score: 1.0, source: :lexical,
        metadata: eligible.find(id), matched_fields: ['identifier:grep_baseline'])
    end
    Woods::Retrieval::SearchExecutor::ExecutionResult.new(candidates: candidates, strategy: :lexical, query: query)
  end
end

end

if $PROGRAM_NAME == __FILE__
  include RetrievalComparison
  runner = RetrievalBaseline::Runner.new
  capture = runner.read('vectors.json')
  runner.verify_capture!(capture)
  stores = runner.stores(capture.fetch('vectors'))
  semantic = Woods::Retriever.new(**stores)
  lexical = Woods::Retriever.new(**stores.merge(vector_store: nil, embedding_provider: nil, mode: :lexical))
  seeded = Woods::Retriever.new(**stores.merge(vector_store: nil, embedding_provider: nil, mode: :lexical))
  original = seeded.pipeline.executor
  experiment = SeededExecutor.new(original, stores[:metadata_store], stores[:graph_store])
  # Preserve the production pipeline object; delegate only the experiment executor.
  original.define_singleton_method(:execute) { |**args| experiment.execute(**args) }
  # Use a separate lexical snapshot inside the delegate to avoid recursion.
  experiment.instance_variable_set(:@lexical, Woods::Retrieval::LexicalIndex.new(metadata_store: stores[:metadata_store]))
  grep = Woods::Retriever.new(**stores.merge(vector_store: nil, embedding_provider: nil, mode: :lexical))
  grep_executor = GrepExecutor.new(stores[:metadata_store])
  grep.pipeline.executor.define_singleton_method(:execute) { |**args| grep_executor.execute(**args) }
  conditions = { semantic: semantic, lexical: lexical, lexical_seeded_graph: seeded, grep: grep }
  report = { schema_version: 1, corpus_sha256: runner.digest('corpus.json'), vectors_sha256: runner.digest('vectors.json'),
    ruby: RUBY_VERSION,
    scope: 'same28 captured Canopy queries and per-query budgets; warm in-process pipeline; semantic uses captured real MiniLM vectors, excludes provider/network time; task outcomes not measured',
    graph_experiment: { restart: 0.15, iterations: 20, edges: 'bidirectional recorded relationships within type eligibility', seeds: 'positive lexical scores normalized', tuning: 'none; fixed before scoring labels' },
    results: conditions.flat_map { |condition, retriever| runner.corpus.fetch('queries').map { |q| runner.measure(retriever, q).merge(condition: condition, budget: q.fetch('budget')) } } }
  File.write(ARGV.fetch(0), JSON.pretty_generate(report) + "\n")
  report[:results].group_by { |r| r[:condition] }.each { |name, rows| puts JSON.generate(condition: name, **runner.aggregate(rows)) }
end
