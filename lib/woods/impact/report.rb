# frozen_string_literal: true

require_relative 'resolver'
require_relative 'endpoint'
require_relative 'range_diff'
require_relative 'enrichment'
require_relative 'focus'

module Woods
  module Impact
    # Immutable versioned range report with bounded typed propagation and retained
    # flow evidence. Deferred analyses explicitly carry not_computed coverage.
    class Report
      DEFERRED = %w[affected flows tables templates tests risks commits focus].freeze

      # Compare two retained payloads without source reads, git or Rails.
      # @param index_dir [String, Pathname]
      # @param from [Integer, String]
      # @param to [Integer, String]
      # @param parameters [Hash] depth, type/via filters and finite work budgets
      # @return [Report]
      def self.compare(index_dir, from:, to: 'now', **parameters)
        options = Options.new(**parameters)
        Resolver.new(index_dir).open(from: from, to: to) do |before, after|
          next unchanged(before, from, to, options) if before.equal?(after)

          base = Endpoint.new(before)
          head = Endpoint.new(after)
          before_units = base.units
          after_units = head.units
          changes = RangeDiff.new(before_units, after_units,
                                  max_source_hunks: options.to_h.fetch('max_source_hunks')).changes
          unknowns = base.unknowns(before_units, 'from') + head.unknowns(after_units, 'to')
          computed = compute([[before, before_units], [after, after_units]], changes, options)
          new({ 'from' => base.provenance(from), 'to' => head.provenance(to) }, changes,
              unknowns: unknowns, computed: computed)
        end
      end

      # Both endpoints are one payload: nothing changed, so no unit is read or
      # compared. The report says so with the same envelope as any range.
      def self.unchanged(reader, from, to, options)
        endpoint = Endpoint.new(reader)
        endpoint.manifest
        new({ 'from' => endpoint.provenance(from), 'to' => endpoint.provenance(to) }, [],
            computed: compute([[reader, []], [reader, []]], [], options))
      end
      private_class_method :unchanged

      # @return [Hash] endpoint-specific propagation and flow evidence
      def self.compute(endpoints, changes, options)
        removed, current = changes.partition { |change| change['status'] == 'removed' }
        enrichment = Enrichment.new(options)
        endpoints.zip([removed, current], %w[from to]).each do |(reader, units), roots, side|
          comparison = endpoints[side == 'from' ? 1 : 0].last
          enrichment.add(reader, units, roots.map { |item| item.values_at('identifier', 'type') }, side,
                         comparison: comparison)
        end
        enrichment.to_h
      end
      private_class_method :compute

      # Plan changes to exact typed units from one retained payload.
      # @param index_dir [String, Pathname]
      # @param identities [Array<Hash>] exact identifier/type pairs
      # @param at [String, Integer] retained selector, default now
      # @param parameters [Hash] bounded propagation and flow options
      # @return [Report]
      def self.focus(index_dir, identities:, at: 'now', **parameters)
        Focus.new(index_dir, identities: identities, at: at, options: Options.new(**parameters)).call
      end

      # @param range [Hash] endpoint provenance
      # @param changes [Array<Hash>] typed changes
      # @param unknowns [Array<Hash>] unavailable endpoint facts
      # @param computed [Hash] bounded propagation and flow evidence
      def initialize(range, changes, unknowns: [], computed: {})
        @data = Value.copy(enrich(build(range, changes, unknowns), computed))
        freeze
      end

      # @return [Hash] recursively frozen, string-keyed JSON value
      def to_h
        @data
      end

      # @return [String] deterministic JSON; no timestamps or generated report ID
      def to_json(*_args)
        JSON.generate(@data)
      end

      private

      def enrich(data, computed)
        return data if computed.empty?

        unknowns = data['unknowns'].reject do |item|
          item['kind'] == 'not_computed' && computed.fetch('coverage').key?(item['feature'])
        end
        data.merge(computed.except('coverage', 'unknowns'))
            .merge('coverage' => data['coverage'].merge(computed.fetch('coverage')),
                   'unknowns' => unknowns + computed.fetch('unknowns'))
      end

      def build(range, changes, endpoint_unknowns)
        coverage = DEFERRED.to_h { |feature| [feature, 'not_computed'] }
                           .merge('complete' => false, 'diff' => 'retained_payloads', 'snapshot_facets' => 'unbound')
        { 'schema_version' => 1, 'range' => range, 'parameters' => { 'mode' => 'range' }, 'changed' => changes,
          'coverage' => coverage, 'unknowns' => endpoint_unknowns + unknowns(changes) }
          .merge(DEFERRED.reject { |key| key == 'focus' }.to_h { |key| [key, []] })
      end

      def unknowns(changes)
        deferred = DEFERRED.map { |feature| { 'kind' => 'not_computed', 'feature' => feature } }
        deferred << { 'kind' => 'snapshot_binding_unavailable' }
        deferred + changes.flat_map { |change| classification_unknowns(change) }
      end

      def classification_unknowns(change)
        identity = change.slice('identifier', 'type')
        known_keys = RangeDiff::CATEGORY_KEYS.values.flatten
        unknown_keys = change['metadata_keys'] - known_keys
        result = []
        if unknown_keys.any?
          result << identity.merge('kind' => 'unclassified_metadata', 'metadata_keys' => unknown_keys)
        end
        if change['facets'].include?('source') && !RangeDiff::SOURCE_CATEGORIES.key?(change['type'])
          result << identity.merge('kind' => 'unclassified_source')
        end
        result
      end
    end
  end
end
