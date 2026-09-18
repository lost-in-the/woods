# frozen_string_literal: true

require_relative 'runner'
require_relative 'owner_overlap_cases'

module OwnerOverlap
  module Comparison
    module_function

    def run
      runner = RetrievalBaseline::Runner.new
      capture = runner.read('vectors.json')
      runner.verify_capture!(capture)
      controls = [false, true].flat_map do |policy|
        stores = runner.stores(capture.fetch('vectors'))
        retriever = Woods::Retriever.new(**stores)
        original = retriever.pipeline.assembler
        trace = nil
        retriever.pipeline.assembler = Assembler.new(metadata_store: stores.fetch(:metadata_store),
                                                     chars_per_token: original.chars_per_token,
                                                     token_counter: original.token_counter,
                                                     origins: Origins.new({}), policy: policy, recorder: ->(rows) { trace = rows })
        runner.corpus.fetch('queries').map do |query|
          runner.measure(retriever, query).merge(condition: policy ? 'overlap' : 'baseline',
                                                budget: query.fetch('budget'), trace: trace, fixture_kind: 'Canopy_unknown_origin')
        end
      end
      fixtures = Cases.all + [Cases.real_source]
      cases = fixtures.flat_map do |fixture|
        [false, true].map do |policy|
          Cases.run(fixture, policy: policy).merge(fixture_kind: fixture[:name].start_with?('woods_') ? 'real_static_source' : 'synthetic')
        end
      end
      { schema_version: 1, corpus_sha256: runner.digest('corpus.json'), vectors_sha256: runner.digest('vectors.json'),
        scope: 'Evaluation-only full-source overlap selection; fixed candidates and scores. No production option or default change. Canopy is unknown-origin negative control.',
        correctness: 'Necessary complete method byte retention and relevant-owner coverage are deterministic evidence measures, not answer quality or agent task correctness. Synthetic task assertions execute only delivered snippets in an isolated namespace; these are not model answers. Agent task correctness and runtime host provenance were not measured for this selection policy.',
        source_snapshots: fixtures.to_h { |fixture| [fixture[:name], fixture[:sources].transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }] },
        fixed_case_gold: fixtures.to_h { |fixture| [fixture[:name], { required_methods: fixture[:required], budget: fixture[:budget] }] },
        results: controls + cases }
    end
  end
end

File.write(ARGV.fetch(0), JSON.pretty_generate(OwnerOverlap::Comparison.run) + "\n") if $PROGRAM_NAME == __FILE__
