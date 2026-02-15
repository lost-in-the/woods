# frozen_string_literal: true

require 'spec_helper'
require 'codebase_index'
require 'codebase_index/evaluation/query_set'
require 'codebase_index/evaluation/evaluator'

RSpec.describe CodebaseIndex::Evaluation::Evaluator do
  let(:retriever) { instance_double('CodebaseIndex::Retriever') }

  let(:queries) do
    [
      CodebaseIndex::Evaluation::QuerySet::Query.new(
        query: 'How does User model work?',
        expected_units: %w[User UserConcern],
        intent: :lookup,
        scope: :specific,
        tags: %w[model]
      ),
      CodebaseIndex::Evaluation::QuerySet::Query.new(
        query: 'Trace order creation',
        expected_units: %w[Order OrdersController],
        intent: :trace,
        scope: :bounded,
        tags: %w[flow]
      )
    ]
  end

  let(:query_set) { CodebaseIndex::Evaluation::QuerySet.new(queries: queries) }

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

    it 'includes tokens_used in each result' do
      report = evaluator.evaluate

      expect(report.results.first.tokens_used).to eq(500)
      expect(report.results.last.tokens_used).to eq(300)
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
    let(:empty_query_set) { CodebaseIndex::Evaluation::QuerySet.new(queries: []) }
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

      simple_qs = CodebaseIndex::Evaluation::QuerySet.new(queries: [queries.first])
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

      simple_qs = CodebaseIndex::Evaluation::QuerySet.new(queries: [queries.first])
      simple_eval = described_class.new(retriever: retriever, query_set: simple_qs)
      report = simple_eval.evaluate

      expect(report.results.first.retrieved_units).to eq([])
    end
  end
end
