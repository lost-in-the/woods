# frozen_string_literal: true

require 'json'
require 'time'      # Time#iso8601 — the file is loadable standalone (EXP-8)
require 'fileutils' # FileUtils.mkdir_p in #save

module Woods
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
        hash = {
          'metadata' => build_metadata(metadata),
          'aggregates' => serialize_aggregates(report.aggregates),
          'results' => report.results.map { |r| serialize_result(r) }
        }
        threshold_report = report.threshold_report
        hash['threshold_report'] = serialize_threshold_report(threshold_report) if threshold_report
        hash
      end

      # Build the metadata section.
      #
      # @param extra [Hash] Additional metadata
      # @return [Hash]
      def build_metadata(extra)
        {
          'generated_at' => Time.now.iso8601,
          'version' => defined?(Woods::VERSION) ? Woods::VERSION : 'unknown'
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

      # Serialize a threshold report (nil-safe values: a missing aggregate has
      # a nil actual/delta, which JSON renders as null rather than raising).
      #
      # @param threshold_report [Evaluator::ThresholdReport]
      # @return [Hash] String-keyed hash
      def serialize_threshold_report(threshold_report)
        {
          'passed' => threshold_report.passed,
          'metrics' => threshold_report.metrics.transform_keys(&:to_s).transform_values do |m|
            m.transform_keys(&:to_s)
          end
        }
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
