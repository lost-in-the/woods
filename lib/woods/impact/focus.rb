# frozen_string_literal: true

module Woods
  module Impact
    # Pre-change planning over exact typed units from one retained endpoint.
    # Method names are never silently widened to their containing class.
    class Focus
      # @param index_dir [String, Pathname]
      # @param identities [Array<Hash>] exact string-keyed typed identities
      # @param at [String, Integer] retained selector
      # @param options [Options] bounded query parameters
      def initialize(index_dir, identities:, at:, options:)
        @index_dir = index_dir
        @identities = identities
        @at = at
        @options = options
      end

      # @return [Report] immutable focus report with no diff range
      def call
        Resolver.new(@index_dir).open(from: @at, to: @at) do |_before, reader|
          endpoint = Endpoint.new(reader)
          units = endpoint.units
          roots = resolve(units)
          enrichment = Enrichment.new(@options)
          enrichment.add(reader, units, roots, 'to')
          computed = enrichment.to_h
          computed['parameters']['mode'] = 'focus'
          computed['coverage']['focus'] = 'typed_units'
          computed.merge!('focus' => roots.map { |id, type| { 'identifier' => id, 'type' => type } },
                          'endpoint' => endpoint.provenance(@at))
          Report.new(nil, [], unknowns: endpoint.unknowns(units, 'to'), computed: computed)
        end
      end

      private

      def resolve(units)
        unless @identities.is_a?(Array) && !@identities.empty? && @identities.size <= 10_000
          raise ArgumentError, 'Focus needs 1..10000 exact typed identities'
        end

        @identities.map do |item|
          unless valid_identity?(item)
            raise ArgumentError, 'Focus identities need exactly string identifier and type fields'
          end

          identity = item.values_at('identifier', 'type')
          raise ResolutionError, 'Focus identity is not present in the selected payload' unless units.key?(identity)

          identity
        end.uniq.sort
      end

      def valid_identity?(item)
        item.is_a?(Hash) && item.keys.sort == %w[identifier type] &&
          item.values.all? { |value| value.is_a?(String) && !value.empty? }
      end
    end
  end
end
