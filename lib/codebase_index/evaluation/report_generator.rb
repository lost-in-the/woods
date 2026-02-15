# frozen_string_literal: true

require 'json'

module CodebaseIndex
  module Evaluation
    # Generates JSON reports from evaluation results.
    #
    # Takes an EvaluationReport and produces a structured JSON document
    # with per-query scores, aggregate metrics, and metadata.
    #
    # @example
    #   generator = ReportGenerator.new
    #   json = generator.generate(report)
    #   generator.save(report, "tmp/eval_report.json")
    #
    class ReportGenerator
      # Generate a JSON string from an evaluation report.
      #
      # @param report [Evaluator::EvaluationReport] Evaluation report
      # @param metadata [Hash] Optional metadata to include
      # @return [String] Pretty-printed JSON
      def generate(report, metadata: {})
        data = build_report_hash(report, metadata)
        JSON.pretty_generate(data)
      end

      # Save an evaluation report to a JSON file.
      #
      # @param report [Evaluator::EvaluationReport] Evaluation report
      # @param path [String] Output file path
      # @param metadata [Hash] Optional metadata to include
      # @return [void]
      def save(report, path, metadata: {})
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, generate(report, metadata: metadata))
      end

      private

      # Build the complete report hash.
      #
      # @param report [Evaluator::EvaluationReport] Evaluation report
      # @param metadata [Hash] Additional metadata
      # @return [Hash]
      def build_report_hash(report, metadata)
        {
          'metadata' => build_metadata(metadata),
          'aggregates' => serialize_aggregates(report.aggregates),
          'results' => report.results.map { |r| serialize_result(r) }
        }
      end

      # Build the metadata section.
      #
      # @param extra [Hash] Additional metadata
      # @return [Hash]
      def build_metadata(extra)
        {
          'generated_at' => Time.now.iso8601,
          'version' => defined?(CodebaseIndex::VERSION) ? CodebaseIndex::VERSION : 'unknown'
        }.merge(extra.transform_keys(&:to_s))
      end

      # Serialize aggregate metrics.
      #
      # @param aggregates [Hash] Aggregate metrics with symbol keys
      # @return [Hash] String-keyed hash
      def serialize_aggregates(aggregates)
        aggregates.transform_keys(&:to_s).transform_values do |v|
          v.is_a?(Float) ? v.round(4) : v
        end
      end

      # Serialize a single query result.
      #
      # @param result [Evaluator::QueryResult] Query result
      # @return [Hash]
      def serialize_result(result)
        {
          'query' => result.query,
          'expected_units' => result.expected_units,
          'retrieved_units' => result.retrieved_units,
          'scores' => result.scores.transform_keys(&:to_s).transform_values { |v| v.round(4) },
          'tokens_used' => result.tokens_used
        }
      end
    end
  end
end
