# frozen_string_literal: true

module Woods
  module Evaluation
    # Aggregates {AblationRunner::Result} values into a per-condition summary
    # (resolution rate, mean tokens/cost/turns, task and error counts) plus
    # the on-minus-off delta (#280).
    class AblationSummary
      DELTA_METRICS = %i[resolution_rate mean_tokens mean_cost_usd mean_turns].freeze

      # @param results [Array<AblationRunner::Result>]
      # @param conditions [Array<Symbol>] subset of `%i[on off]`
      # @return [Hash{Symbol=>Hash}]
      def self.build(results, conditions)
        new(results, conditions).build
      end

      def initialize(results, conditions)
        @results = results
        @conditions = conditions
      end

      def build
        summary = {}
        @conditions.each { |condition| summary[condition] = condition_summary(condition) }
        summary[:delta] = delta(summary[:on], summary[:off]) if summary.key?(:on) && summary.key?(:off)
        summary
      end

      private

      def condition_summary(condition)
        results = @results.select { |result| result.condition == condition }
        {
          resolution_rate: resolution_rate(results),
          mean_tokens: mean(results.map(&:total_tokens)),
          mean_cost_usd: mean(results.map(&:cost_usd)),
          mean_turns: mean(results.map(&:turns)),
          tasks: results.size,
          errors: results.count(&:error)
        }
      end

      def resolution_rate(results)
        return 0.0 if results.empty?

        (results.count(&:resolved).to_f / results.size).round(4)
      end

      def delta(on, off)
        DELTA_METRICS.to_h do |key|
          value = on[key].nil? || off[key].nil? ? nil : (on[key] - off[key]).round(4)
          [key, value]
        end
      end

      def mean(values)
        present = values.compact
        return nil if present.empty?

        (present.sum.to_f / present.size).round(4)
      end
    end
  end
end
