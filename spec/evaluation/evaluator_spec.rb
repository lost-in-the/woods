# frozen_string_literal: true

require 'spec_helper'
require 'woods'
require 'woods/evaluation/query_set'
require 'woods/evaluation/evaluator'

RSpec.describe Woods::Evaluation::Evaluator do
  let(:retriever) { instance_double(Woods::Retriever) }

  let(:queries) do
    [
      Woods::Evaluation::QuerySet::Query.new(
        query: 'How does User model work?',
        expected_units: %w[User UserConcern],
        intent: :lookup,
        scope: :specific,
        tags: %w[model]
      ),
      Woods::Evaluation::QuerySet::Query.new(
        query: 'Trace order creation',
        expected_units: %w[Order OrdersController],
        intent: :trace,
        scope: :bounded,
        tags: %w[flow]
      )
    ]
  end

  let(:query_set) { Woods::Evaluation::QuerySet.new(queries: queries) }

  let(:result_struct) do
    Struct.new(:context, :sources, :classification, :strategy, :tokens_used, :budget,
               keyword_init: true)
  end

  let(:retrieval_result_one) do
    result_struct.new(
      context: '## User\nclass User < ApplicationRecord; end',
      sources: [
        { identifier: 'User', type: :model, score: 0.9 },
        { identifier: 'UserConcern', type: :concern, score: 0.8 },
        { identifier: 'Post', type: :model, score: 0.5 }
      ],
      classification: nil,
      strategy: :vector,
      tokens_used: 500,
      budget: 8000
    )
  end

  let(:retrieval_result_two) do
    result_struct.new(
      context: '## Order\nclass Order < ApplicationRecord; end',
      sources: [
        { identifier: 'Order', type: :model, score: 0.95 },
        { identifier: 'Product', type: :model, score: 0.6 }
      ],
      classification: nil,
      strategy: :vector,
      tokens_used: 300,
      budget: 8000
    )
  end

  let(:evaluator) { described_class.new(retriever: retriever, query_set: query_set) }

  before do
    allow(retriever).to receive(:retrieve)
      .with('How does User model work?', budget: 8000)
      .and_return(retrieval_result_one)
    allow(retriever).to receive(:retrieve)
      .with('Trace order creation', budget: 8000)
      .and_return(retrieval_result_two)
  end

  describe '#evaluate' do
    it 'returns an EvaluationReport' do
      report = evaluator.evaluate

      expect(report).to be_a(described_class::EvaluationReport)
    end

    it 'produces one result per query' do
      report = evaluator.evaluate

      expect(report.results.size).to eq(2)
    end

    it 'includes query text in each result' do
      report = evaluator.evaluate

      expect(report.results.first.query).to eq('How does User model work?')
      expect(report.results.last.query).to eq('Trace order creation')
    end

    it 'includes expected_units in each result' do
      report = evaluator.evaluate

      expect(report.results.first.expected_units).to eq(%w[User UserConcern])
    end

    it 'includes retrieved identifiers in each result' do
      report = evaluator.evaluate

      expect(report.results.first.retrieved_units).to eq(%w[User UserConcern Post])
    end

    it 'computes scores for each result' do
      report = evaluator.evaluate

      scores = report.results.first.scores
      expect(scores).to include(:precision_at5, :recall, :mrr, :context_completeness)
    end

    it 'computes recall correctly for first query' do
      report = evaluator.evaluate

      # User and UserConcern both retrieved, 2/2 = 1.0
      expect(report.results.first.scores[:recall]).to eq(1.0)
    end

    it 'computes recall correctly for second query' do
      report = evaluator.evaluate

      # Order retrieved but not OrdersController, 1/2 = 0.5
      expect(report.results.last.scores[:recall]).to eq(0.5)
    end

    it 'computes MRR correctly' do
      report = evaluator.evaluate

      # First result is relevant for query 1
      expect(report.results.first.scores[:mrr]).to eq(1.0)
      # First result is relevant for query 2
      expect(report.results.last.scores[:mrr]).to eq(1.0)
    end

    # EXP-10. `compute_scores` passed `expected` as both the relevant set and
    # the required set, so `context_completeness` was recall under a second
    # name — a dashboard keyed on it silently gated on recall. `required_units`
    # is now a real (optional) annotation on the query.
    it 'diverges from recall when the query names a required subset' do
      required_queries = [
        Woods::Evaluation::QuerySet::Query.new(
          query: 'Trace order creation',
          expected_units: %w[Order OrdersController],
          required_units: %w[Order],
          intent: :trace,
          scope: :focused,
          tags: %w[flow]
        )
      ]
      allow(retriever).to receive(:retrieve).and_return(retrieval_result_two)

      report = described_class.new(
        retriever: retriever,
        query_set: Woods::Evaluation::QuerySet.new(queries: required_queries)
      ).evaluate

      # Order retrieved, OrdersController not: recall 1/2, completeness 1/1.
      expect(report.results.first.scores[:recall]).to eq(0.5)
      expect(report.results.first.scores[:context_completeness]).to eq(1.0)
    end

    it 'falls back to the expected set when no required subset is annotated' do
      report = evaluator.evaluate

      expect(report.results.last.scores[:context_completeness]).to eq(report.results.last.scores[:recall])
    end

    it 'includes tokens_used in each result' do
      report = evaluator.evaluate

      expect(report.results.first.tokens_used).to eq(500)
      expect(report.results.last.tokens_used).to eq(300)
    end
  end

  # F11. `token_efficiency` was `ceil(tokens_used * relevant/retrieved) /
  # tokens_used`: the share of returned *units* that were expected, up to a
  # rounding artefact, and blind to how many tokens each unit cost. That
  # number survives as `unit_precision`; `token_efficiency` is now the share
  # of the rendered context spent on expected units, read from the `tokens`
  # each source reports, and says which basis it used.
  describe 'token efficiency' do
    def result_with(sources, tokens_used:)
      result_struct.new(context: '', sources: sources, classification: nil, strategy: :vector,
                        tokens_used: tokens_used, budget: 8000)
    end

    def single_query_report(sources, tokens_used:, expected: %w[User UserConcern])
      query = Woods::Evaluation::QuerySet::Query.new(query: 'q', expected_units: expected,
                                                     intent: :lookup, scope: :specific, tags: [])
      allow(retriever).to receive(:retrieve).and_return(result_with(sources, tokens_used: tokens_used))
      described_class.new(retriever: retriever, query_set: Woods::Evaluation::QuerySet.new(queries: [query])).evaluate
    end

    it 'scores unit_precision as the share of returned units that were expected' do
      report = evaluator.evaluate

      # Query 1: User, UserConcern expected of three returned; query 2: Order of two.
      expect(report.results.first.scores[:unit_precision]).to be_within(0.0001).of(2.0 / 3)
      expect(report.results.last.scores[:unit_precision]).to eq(0.5)
      expect(report.aggregates[:mean_unit_precision]).to be_within(0.0001).of(((2.0 / 3) + 0.5) / 2)
    end

    it 'scores token_efficiency as the rendered-token share of expected units' do
      report = single_query_report(
        [{ identifier: 'User', tokens: 100 }, { identifier: 'UserConcern', tokens: 50 },
         { identifier: 'Post', tokens: 850 }],
        tokens_used: 1000
      )

      # 2 of 3 units are expected, but they hold 150 of the 1,000 tokens.
      expect(report.results.first.scores[:unit_precision]).to be_within(0.0001).of(2.0 / 3)
      expect(report.results.first.scores[:token_efficiency]).to eq(0.15)
      expect(report.results.first.token_efficiency_basis).to eq(:rendered_tokens)
      expect(report.token_efficiency_basis).to eq(:rendered_tokens)
    end

    it 'does not credit a lone expected unit with the whole context' do
      report = single_query_report([{ identifier: 'User', tokens: 50 }, { identifier: 'Post', tokens: 7950 }],
                                   tokens_used: 8000)

      expect(report.results.first.scores[:token_efficiency]).to eq(0.00625)
    end

    it 'caps the share at 1.0 when source tokens exceed the counted context' do
      report = single_query_report([{ identifier: 'User', tokens: 120 }], tokens_used: 100)

      expect(report.results.first.scores[:token_efficiency]).to eq(1.0)
    end

    it 'falls back to unit_precision, and says so, when sources carry no token figure' do
      report = evaluator.evaluate

      expect(report.results.first.scores[:token_efficiency]).to eq(report.results.first.scores[:unit_precision])
      expect(report.results.first.token_efficiency_basis).to eq(:unit_precision)
      expect(report.token_efficiency_basis).to eq(:unit_precision)
    end

    it 'falls back for the whole query when any source lacks a token figure' do
      report = single_query_report([{ identifier: 'User', tokens: 100 }, { identifier: 'Post' }], tokens_used: 1000)

      expect(report.results.first.scores[:token_efficiency]).to eq(0.5)
      expect(report.results.first.token_efficiency_basis).to eq(:unit_precision)
    end

    it 'reports a mixed basis when queries disagree' do
      with_tokens = result_with([{ identifier: 'User', tokens: 100 }, { identifier: 'Post', tokens: 100 }],
                                tokens_used: 200)
      allow(retriever).to receive(:retrieve).with('How does User model work?', budget: 8000).and_return(with_tokens)

      report = evaluator.evaluate

      expect(report.results.map(&:token_efficiency_basis)).to eq(%i[rendered_tokens unit_precision])
      expect(report.token_efficiency_basis).to eq(:mixed)
    end

    it 'scores zero when nothing was rendered' do
      report = single_query_report([], tokens_used: 0)

      expect(report.results.first.scores[:unit_precision]).to eq(0.0)
      expect(report.results.first.scores[:token_efficiency]).to eq(0.0)
    end

    it 'keeps the basis out of the numeric aggregates' do
      report = evaluator.evaluate

      expect(report.aggregates.values).to all(be_a(Numeric))
      expect(report.aggregates).not_to have_key(:token_efficiency_basis)
    end

    it 'reports no basis for an empty query set' do
      report = described_class.new(retriever: retriever,
                                   query_set: Woods::Evaluation::QuerySet.new(queries: [])).evaluate

      expect(report.token_efficiency_basis).to eq(:none)
    end
  end

  describe 'aggregates' do
    it 'computes mean metrics across all queries' do
      report = evaluator.evaluate

      expect(report.aggregates[:total_queries]).to eq(2)
      expect(report.aggregates).to include(
        :mean_precision_at5,
        :mean_precision_at10,
        :mean_recall,
        :mean_mrr,
        :mean_context_completeness,
        :mean_unit_precision,
        :mean_token_efficiency
      )
    end

    it 'computes mean recall' do
      report = evaluator.evaluate

      # Query 1: recall 1.0, Query 2: recall 0.5 => mean 0.75
      expect(report.aggregates[:mean_recall]).to eq(0.75)
    end

    it 'computes mean MRR' do
      report = evaluator.evaluate

      # Both queries have MRR 1.0
      expect(report.aggregates[:mean_mrr]).to eq(1.0)
    end

    it 'computes mean tokens used' do
      report = evaluator.evaluate

      # (500 + 300) / 2 = 400.0
      expect(report.aggregates[:mean_tokens_used]).to eq(400.0)
    end
  end

  describe 'with empty query set' do
    let(:empty_query_set) { Woods::Evaluation::QuerySet.new(queries: []) }
    let(:empty_evaluator) { described_class.new(retriever: retriever, query_set: empty_query_set) }

    it 'returns empty results' do
      report = empty_evaluator.evaluate

      expect(report.results).to be_empty
    end

    it 'returns zero aggregates' do
      report = empty_evaluator.evaluate

      expect(report.aggregates[:total_queries]).to eq(0)
      expect(report.aggregates[:mean_recall]).to eq(0.0)
      expect(report.aggregates[:mean_mrr]).to eq(0.0)
    end
  end

  describe 'thresholds' do
    it 'leaves threshold_report nil when no thresholds are given (report-only, unchanged)' do
      report = evaluator.evaluate

      expect(report.threshold_report).to be_nil
    end

    it 'passes when every aggregate meets its threshold' do
      evaluator_with_thresholds = described_class.new(
        retriever: retriever, query_set: query_set,
        thresholds: { mean_recall: 0.5, mean_mrr: 1.0 }
      )

      report = evaluator_with_thresholds.evaluate

      expect(report.threshold_report.passed).to be(true)
      expect(report.threshold_report.metrics[:mean_recall]).to include(threshold: 0.5, actual: 0.75, passed: true)
      expect(report.threshold_report.metrics[:mean_recall][:delta]).to be_within(0.0001).of(0.25)
    end

    it 'fails with a per-metric delta when an aggregate misses its threshold' do
      evaluator_with_thresholds = described_class.new(
        retriever: retriever, query_set: query_set,
        thresholds: { mean_recall: 0.9 }
      )

      report = evaluator_with_thresholds.evaluate

      expect(report.threshold_report.passed).to be(false)
      metric = report.threshold_report.metrics[:mean_recall]
      expect(metric[:passed]).to be(false)
      expect(metric[:delta]).to be_within(0.0001).of(-0.15)
    end

    it 'treats an empty thresholds hash the same as absent thresholds' do
      evaluator_with_thresholds = described_class.new(retriever: retriever, query_set: query_set, thresholds: {})

      report = evaluator_with_thresholds.evaluate

      expect(report.threshold_report).to be_nil
    end
  end

  describe 'with custom budget' do
    it 'passes budget to retriever' do
      custom_evaluator = described_class.new(retriever: retriever, query_set: query_set, budget: 4000)

      allow(retriever).to receive(:retrieve).and_return(retrieval_result_one)

      custom_evaluator.evaluate

      expect(retriever).to have_received(:retrieve).with(anything, budget: 4000).twice
    end
  end

  describe 'identifier extraction' do
    it 'handles sources with string keys' do
      string_key_result = result_struct.new(
        context: 'test',
        sources: [{ 'identifier' => 'User', 'type' => 'model' }],
        classification: nil,
        strategy: :vector,
        tokens_used: 100,
        budget: 8000
      )

      allow(retriever).to receive(:retrieve).and_return(string_key_result)

      simple_qs = Woods::Evaluation::QuerySet.new(queries: [queries.first])
      simple_eval = described_class.new(retriever: retriever, query_set: simple_qs)
      report = simple_eval.evaluate

      expect(report.results.first.retrieved_units).to include('User')
    end

    it 'handles nil sources gracefully' do
      nil_sources_result = result_struct.new(
        context: 'test',
        sources: nil,
        classification: nil,
        strategy: :vector,
        tokens_used: 100,
        budget: 8000
      )

      allow(retriever).to receive(:retrieve).and_return(nil_sources_result)

      simple_qs = Woods::Evaluation::QuerySet.new(queries: [queries.first])
      simple_eval = described_class.new(retriever: retriever, query_set: simple_qs)
      report = simple_eval.evaluate

      expect(report.results.first.retrieved_units).to eq([])
    end
  end
end
