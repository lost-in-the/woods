# frozen_string_literal: true

require_relative 'runner'

module EvidenceComparison
  # Changes only evidence rendering. Queries, gold labels, rankers and budgets
  # remain the reviewed #227 capture; no method-level gold is inferred from it.
  class Mode
    def initialize(retriever, evidence)
      @retriever, @evidence = retriever, evidence
    end

    attr_reader :last_result

    def retrieve(query, **options)
      @last_result = @retriever.retrieve(query, **options, evidence: @evidence)
    end
  end

  def self.run
    runner = RetrievalBaseline::Runner.new
    capture = runner.read('vectors.json')
    runner.verify_capture!(capture)
    stores = runner.stores(capture.fetch('vectors'))
    retrievers = { semantic: Woods::Retriever.new(**stores),
                   lexical: Woods::Retriever.new(**stores.merge(vector_store: nil, embedding_provider: nil, mode: :lexical)) }
    results = retrievers.flat_map do |strategy, retriever|
      %w[full compact outline].flat_map do |evidence|
        mode = Mode.new(retriever, evidence)
        runner.corpus.fetch('queries').map do |query|
          measured = runner.measure(mode, query)
          selected = mode.last_result.sources.filter_map do |source|
            data = source[:evidence]
            next unless data

            { identifier: source[:identifier], type: source[:type], selected_spans: data[:spans].size,
              selected_runtime_fields: data[:runtime_fields], omitted_spans: data[:omitted_spans] }
          end
          measured.merge(condition: "#{strategy}_#{evidence}", budget: query.fetch('budget'), evidence_units: selected)
        end
      end
    end
    { schema_version: 1, corpus_sha256: runner.digest('corpus.json'), vectors_sha256: runner.digest('vectors.json'),
      scope: 'same28 captured Canopy queries, gold labels and per-query budgets; evidence mode is the only within-strategy variable; warm replay excludes provider/network; task correctness and method relevance not measured',
      results: results }
  end
end

if $PROGRAM_NAME == __FILE__
  report = EvidenceComparison.run
  File.write(ARGV.fetch(0), JSON.pretty_generate(report) + "\n")
end
