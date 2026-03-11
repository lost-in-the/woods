# frozen_string_literal: true

require_relative 'metrics'

module CodebaseIndex
  module Evaluation
    # Runs evaluation queries through a Retriever and scores results
    # against ground truth annotations.
    #
    # Takes a configured retriever and a query set, runs each query,
    # and produces per-query and aggregate metrics.
    #
    # @example
    #   evaluator = Evaluator.new(retriever: retriever, query_set: query_set)
    #   report = evaluator.evaluate
    #   report.aggregates[:mean_mrr]  # => 0.75
    #
    class Evaluator
      # Result for a single evaluation query.
      QueryResult = Struct.new(:query, :expected_units, :retrieved_units, :scores, :tokens_used,
                               keyword_init: true)

      # Aggregate report across all queries.
      EvaluationReport = Struct.new(:results, :aggregates, keyword_init: true)

      METRIC_KEYS = %i[precision_at5 precision_at10 recall mrr context_completeness token_efficiency].freeze

      # @param retriever [CodebaseIndex::Retriever] Configured retriever instance
      # @param query_set [QuerySet] Set of evaluation queries with ground truth
      # @param budget [Integer] Token budget per query
      def initialize(retriever:, query_set:, budget: 8000)
        @retriever = retriever
        @query_set = query_set
        @budget = budget
      end

      # Run all queries and produce an evaluation report.
      #
      # @return [EvaluationReport] Per-query results and aggregate metrics
      def evaluate
        results = @query_set.queries.map { |q| evaluate_query(q) }
        aggregates = compute_aggregates(results)
        EvaluationReport.new(results: results, aggregates: aggregates)
      end

      private

      # Evaluate a single query against the retriever.
      #
      # @param query [QuerySet::Query] Evaluation query
      # @return [QueryResult]
      def evaluate_query(query)
        retrieval_result = @retriever.retrieve(query.query, budget: @budget)
        retrieved_ids = extract_identifiers(retrieval_result)

        scores = compute_scores(retrieved_ids, query.expected_units, retrieval_result)

        QueryResult.new(
          query: query.query,
          expected_units: query.expected_units,
          retrieved_units: retrieved_ids,
          scores: scores,
          tokens_used: retrieval_result.tokens_used
        )
      end

      # Extract unit identifiers from retrieval result sources.
      #
      # @param result [Retriever::RetrievalResult] Retrieval result
      # @return [Array<String>] Ordered list of unit identifiers
      def extract_identifiers(result)
        return [] unless result.sources

        result.sources.map { |s| s.is_a?(Hash) ? s[:identifier] || s['identifier'] : s.to_s }
      end

      # Compute all metrics for a query result.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param expected [Array<String>] Expected identifiers
      # @param result [Retriever::RetrievalResult] Retrieval result
      # @return [Hash] Metric scores
      def compute_scores(retrieved, expected, result)
        {
          precision_at5: Metrics.precision_at_k(retrieved, expected, cutoff: 5),
          precision_at10: Metrics.precision_at_k(retrieved, expected, cutoff: 10),
          recall: Metrics.recall(retrieved, expected),
          mrr: Metrics.mrr(retrieved, expected),
          context_completeness: Metrics.context_completeness(retrieved, expected),
          token_efficiency: compute_token_efficiency(retrieved, expected, result)
        }
      end

      # Compute token efficiency from the retrieval result.
      #
      # @param retrieved [Array<String>] Retrieved identifiers
      # @param expected [Array<String>] Expected identifiers
      # @param result [Retriever::RetrievalResult] Retrieval result
      # @return [Float]
      def compute_token_efficiency(retrieved, expected, result)
        return 0.0 if result.tokens_used.nil? || result.tokens_used.zero?

        expected_set = expected.to_set
        relevant_count = retrieved.count { |id| expected_set.include?(id) }
        total_count = [retrieved.size, 1].max
        relevant_ratio = relevant_count.to_f / total_count

        Metrics.token_efficiency((result.tokens_used * relevant_ratio).ceil, result.tokens_used)
      end

      # Compute aggregate metrics across all query results.
      #
      # @param results [Array<QueryResult>] Individual query results
      # @return [Hash] Aggregate metrics
      def compute_aggregates(results)
        return empty_aggregates if results.empty?

        aggregates = {}

        METRIC_KEYS.each do |key|
          values = results.map { |r| r.scores[key] }
          aggregates[:"mean_#{key}"] = values.sum / values.size.to_f
        end

        aggregates[:total_queries] = results.size
        aggregates[:mean_tokens_used] = results.sum(&:tokens_used) / results.size.to_f
        aggregates
      end

      # Return zero-valued aggregates for empty result sets.
      #
      # @return [Hash]
      def empty_aggregates
        METRIC_KEYS.to_h { |key| [:"mean_#{key}", 0.0] }
                   .merge(total_queries: 0, mean_tokens_used: 0.0)
      end
    end
  end
end
