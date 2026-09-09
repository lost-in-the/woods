# frozen_string_literal: true

require 'set'

module Woods
  module Checks
    # Public methods that look like they moved from one unit to another
    # between two generations while their test coverage did not follow
    # (#280, 2026-09-09 ruling).
    #
    # A refactor that pulls `total` out of `Checkout` into `Pricing` keeps
    # `spec/checkout_spec.rb` green only until the old call site goes; if
    # nothing covers `Pricing`, the moved message is now untested. The check
    # is a set difference over method lists in two {Woods::PublishedIndex}
    # generations, joined with `:test_coverage` edges from the same
    # generations.
    #
    # Each row is a **candidate** move into a unit without mapped tests, not
    # a proven coverage loss: matching is by name and kind alone, so two
    # unrelated methods that happen to share both are indistinguishable from
    # a real move. This is a heuristic by design (see `docs/PUBLISHED_INDEX.md`
    # and the rake task's `desc`), and is reported only when the source unit
    # was covered before and the destination unit is not covered after; a
    # method that was never covered is not a regression this check owns.
    #
    # Consumes anything shaped like {Woods::PublishedIndex}: `#units`,
    # `#unit(identifier)`, and `#edges(via:)`. It never opens an index
    # itself, so it needs no Rails and takes no retention lock of its own.
    #
    # @example
    #   before = Woods::PublishedIndex.new(dir, generation: 41)
    #   after  = Woods::PublishedIndex.new(dir, generation: 42)
    #   Woods::Checks::MovedMessages.new(before: before, after: after).run
    #   # => [#<Finding method="total" kind=:instance from_unit="Checkout" ...>]
    #
    class MovedMessages
      # Metadata keys extractors use for method lists (see
      # `docs/PUBLISHED_INDEX.md`'s "Moved-message check" section for which
      # extractor writes which key).
      METHOD_KEYS = %w[public_methods instance_methods class_methods].freeze

      COVERAGE_VIA = 'test_coverage'

      # @!attribute method
      #   @return [String] the method name, `self.`-prefix stripped
      # @!attribute kind
      #   @return [Symbol] `:instance` or `:class`
      # @!attribute from_unit
      #   @return [String] identifier that lost the method
      # @!attribute to_unit
      #   @return [String] identifier that gained the method
      # @!attribute covered_before
      #   @return [Boolean] whether `from_unit` had a `:test_coverage` edge before
      # @!attribute covered_after
      #   @return [Boolean] whether `to_unit` has a `:test_coverage` edge after
      # rubocop:disable Lint/StructNewOverride -- :method is the field name docs and callers already use
      Finding = Struct.new(:method, :kind, :from_unit, :to_unit, :covered_before, :covered_after, keyword_init: true) do
        # rubocop:enable Lint/StructNewOverride
        # @return [Hash] symbol-keyed, ready for JSON
        def to_h
          { method: method, kind: kind, from_unit: from_unit, to_unit: to_unit,
            covered_before: covered_before, covered_after: covered_after }
        end
      end

      # @param before [Woods::PublishedIndex] the older generation
      # @param after [Woods::PublishedIndex] the newer generation
      def initialize(before:, after:)
        @before = before
        @after = after
      end

      # @return [Array<Finding>] sorted by method, then kind, then source, then destination
      def run
        removed, added = method_moves
        covered_before = covered_units(@before)
        covered_after = covered_units(@after)

        removed.keys.sort_by { |name, kind| [name, kind.to_s] }.flat_map do |signature|
          destinations = added[signature]
          next [] unless destinations

          build_findings(signature, removed[signature], destinations, covered_before, covered_after)
        end
      end

      private

      # @param signature [Array(String, Symbol)] `[method_name, kind]`
      # @param sources [Array<String>] units that lost it
      # @param destinations [Array<String>] units that gained it
      # @param covered_before [Set<String>]
      # @param covered_after [Set<String>]
      # @return [Array<Finding>]
      def build_findings(signature, sources, destinations, covered_before, covered_after)
        name, kind = signature

        sources.sort.product(destinations.sort).filter_map do |from_unit, to_unit|
          next if from_unit == to_unit

          finding = Finding.new(method: name, kind: kind, from_unit: from_unit, to_unit: to_unit,
                                covered_before: covered_before.include?(from_unit),
                                covered_after: covered_after.include?(to_unit))
          finding if finding.covered_before && !finding.covered_after
        end
      end

      # @return [Array(Hash, Hash)] `[method_kind, unit] => units that lost/gained it`
      def method_moves
        before_methods = method_index(@before)
        after_methods = method_index(@after)
        [signature_losses(before_methods, after_methods), signature_losses(after_methods, before_methods)]
      end

      # Signatures an identifier has in +from+ but not in +to+, grouped by
      # signature. "Removed" and "added" are the same computation with the
      # two method-index hashes swapped, so both come from this one method.
      #
      # @param from [Hash{String => Set}]
      # @param to [Hash{String => Set}]
      # @return [Hash{Array(String, Symbol) => Array<String>}]
      def signature_losses(from, to)
        losses = Hash.new { |hash, key| hash[key] = [] }
        (from.keys | to.keys).each do |identifier|
          lost = (from[identifier] || Set.new) - (to[identifier] || Set.new)
          lost.each { |signature| losses[signature] << identifier }
        end
        losses
      end

      # identifier => Set of `[name, kind]` signatures, for units that list any.
      #
      # @param reader [Woods::PublishedIndex]
      # @return [Hash{String => Set<Array(String, Symbol)>}]
      def method_index(reader)
        reader.units.each_with_object({}) do |entry, index|
          data = reader.unit(entry['identifier'])
          next unless data

          signatures = METHOD_KEYS.flat_map { |key| normalized_signatures(key, data.dig('metadata', key)) }
          index[entry['identifier']] = signatures.to_set if signatures.any?
        end
      end

      # Normalizes a raw metadata method name into a `[name, kind]` signature.
      #
      # `public_methods` (regex-extracted) mixes instance and class methods in
      # one list, marking a class method with a literal `self.` prefix.
      # `class_methods` and `instance_methods` are already split by key, with
      # no prefix on the name. Normalizing both shapes to the same
      # `[name, kind]` pair is what lets a `self.build` in one unit's
      # `public_methods` match a bare `build` in another unit's
      # `class_methods`, and, just as importantly, keeps an instance method
      # from matching a class method of the same bare name.
      #
      # @param key [String] the metadata key the names came from
      # @param names [Array<String>, nil]
      # @return [Array<Array(String, Symbol)>]
      def normalized_signatures(key, names)
        Array(names).map do |raw|
          name = raw.to_s
          if name.start_with?('self.')
            [name.delete_prefix('self.'), :class]
          else
            [name, key == 'class_methods' ? :class : :instance]
          end
        end
      end

      # @param reader [Woods::PublishedIndex]
      # @return [Set<String>] identifiers some test_mapping unit covers
      def covered_units(reader)
        reader.edges(via: COVERAGE_VIA).to_set { |edge| edge[:to] }
      end
    end
  end
end
