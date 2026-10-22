# frozen_string_literal: true

require_relative 'value'
require_relative 'risk_budget'
require 'set'

module Woods
  module Impact
    # Evidence-only metadata comparisons; missing policy facts are never negatives.
    class MetadataRisks
      REQUIRED = { 'model' => ['callbacks'], 'controller' => ['filters'],
                   'database_table' => ['foreign_keys'] }.freeze
      # @param type [String] actual unit type
      def initialize(type, budget: RiskBudget.new(10_000))
        @type = type
        @budget = budget
      end

      # @param before [Hash, nil] base metadata; nil for focus or added units
      # @param after [Hash, nil] head metadata; nil for removed units
      # @param current [Hash] metadata belonging to the reported endpoint
      # @return [Hash] risks and unknowns without endpoint context
      def call(before, after, current:)
        @risks = []
        @unknowns = []
        reason = catch(:risk_budget) do
          compare(before, after) if before && after
          retry_policy(current) if @type == 'job'
          nil
        end
        unknown(reason) if reason
        { 'risks' => @risks, 'unknowns' => @unknowns }
      end

      private

      def compare(before, after)
        changed_array(before, after, 'filters', 'filter_chain_change') if recorded?('filters', before, after)
        callbacks(before['callbacks'], after['callbacks']) if recorded?('callbacks', before, after)
        foreign_keys(before, after) if recorded?('foreign_keys', before, after)
      end

      def recorded?(key, before, after)
        REQUIRED.fetch(@type, []).include?(key) || before.key?(key) || after.key?(key)
      end

      def changed_array(before, after, key, kind)
        old = before[key]
        current = after[key]
        return unknown("#{key}_unavailable") unless old.is_a?(Array) && current.is_a?(Array)

        @budget.consume(old.size + current.size)
        return if Value.json(old) == Value.json(current)

        risk(kind, 'metadata_key' => key, 'before_count' => old.size, 'after_count' => current.size)
      end

      def callbacks(before, after)
        old = effects(before)
        current = effects(after)
        return unknown('callback_side_effects_unavailable') unless old && current
        return if Value.json(old) == Value.json(current)

        risk('callback_side_effect_change', 'metadata_key' => 'callbacks.side_effects',
                                            'before' => old, 'after' => current)
      end

      def effects(callbacks)
        return unless callbacks.is_a?(Array)

        @budget.consume(callbacks.size)
        return unless callbacks.all? { |item| item.is_a?(Hash) && item['side_effects'].is_a?(Hash) }

        callbacks.map { |item| item.slice('filter', 'type', 'kind', 'conditions', 'name', 'event', 'side_effects') }
      end

      def foreign_keys(before, after)
        old = before['foreign_keys']
        current = after['foreign_keys']
        return unknown('foreign_key_evidence_unavailable') unless old.is_a?(Array) && current.is_a?(Array)

        @budget.consume(old.size + current.size)
        # Legacy producers use [] for failed/unsupported capture as well as known-empty schemas.
        return unknown('foreign_key_capture_completeness_unavailable') if old.empty? || current.empty?

        current_keys = current.to_set { |item| Value.json(item) }
        removed = old.reject { |key| current_keys.include?(Value.json(key)) }
        return if removed.empty?

        risk('dropped_foreign_key', 'metadata_key' => 'foreign_keys', 'removed' => removed)
      end

      def retry_policy(metadata)
        config = metadata['retry_config']
        options = metadata['sidekiq_options']
        value = config['sidekiq_retries'] if config.is_a?(Hash)
        value = options['retry'] if options.is_a?(Hash) && options.key?('retry')
        return if retry_enabled?(metadata, value)
        return unknown('job_retry_policy_unavailable') unless metadata['job_type'] == 'sidekiq'

        return unknown('job_retry_policy_unavailable') unless [false, 0, 'false', '0'].include?(value)

        risk('job_without_retry_touched', 'metadata_key' => 'retry_config/sidekiq_options', 'explicit_retry' => value)
      end

      def retry_enabled?(metadata, value)
        (metadata['retry_on'].is_a?(Array) && !metadata['retry_on'].empty?) || value == true ||
          (value.is_a?(Numeric) && value.positive?) || (value.is_a?(String) && value.match?(/\A[1-9]\d*\z/))
      end

      def risk(kind, evidence)
        @risks << { 'kind' => kind, 'evidence' => evidence }
      end

      def unknown(kind)
        @unknowns << { 'kind' => kind }
      end
    end
  end
end
