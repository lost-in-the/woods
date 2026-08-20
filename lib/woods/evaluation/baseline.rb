# frozen_string_literal: true

require 'json'

module Woods
  module Evaluation
    # Loads a versioned baseline/thresholds file for `woods:evaluate`.
    #
    # File shape (schema_version 1):
    #
    #   {
    #     "schema_version": 1,
    #     "query_set": "config/eval_queries.json",
    #     "captured_at": "2026-08-20T00:00:00Z",   // or null if never captured
    #     "thresholds": {
    #       "mean_precision_at5": 0.0,
    #       "mean_recall": 0.0,
    #       "mean_mrr": 0.0
    #     },
    #     "notes": "free text"
    #   }
    #
    # `thresholds` keys must match {Evaluator::EvaluationReport}'s +aggregates+
    # keys (e.g. "mean_recall", not "recall") — the evaluator compares them
    # directly against computed aggregates.
    #
    # The checked-in example under spec/fixtures/evaluation_baseline.example.json
    # is a format fixture only: its thresholds are 0.0 placeholders, not a
    # captured v2 corpus baseline. Capturing the real baseline — running the
    # harness against the pinned v2 corpus and recording the resulting scores
    # as thresholds — is future work.
    class Baseline
      SUPPORTED_SCHEMA_VERSIONS = [1].freeze

      Data = Struct.new(:schema_version, :query_set, :captured_at, :thresholds, :notes, keyword_init: true)

      class << self
        # @param path [String] path to a baseline JSON file
        # @return [Data]
        # @raise [Woods::Error] on an unreadable file, invalid JSON, or an
        #   unsupported schema_version
        def load(path)
          raw = JSON.parse(File.read(path.to_s, encoding: 'UTF-8'))
          version = raw['schema_version']
          unless SUPPORTED_SCHEMA_VERSIONS.include?(version)
            raise Woods::Error, "Unsupported baseline schema_version #{version.inspect} in #{path}"
          end

          Data.new(
            schema_version: version,
            query_set: raw['query_set'],
            captured_at: raw['captured_at'],
            thresholds: (raw['thresholds'] || {}).transform_keys(&:to_sym),
            notes: raw['notes']
          )
        end
      end
    end
  end
end
