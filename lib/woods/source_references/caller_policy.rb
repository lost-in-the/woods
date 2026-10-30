# frozen_string_literal: true

require 'set'
require_relative 'registry'

module Woods
  module SourceReferences
    # Which unit types publish verified `code_reference` edges, and which
    # target types each of them may reference. Admission is explicit: a type
    # absent from the policy keeps its collected candidates and adds no edge.
    #
    # The policy only narrows what {Registry} already verified. It never
    # resolves a constant and cannot admit a target the registry rejected.
    class CallerPolicy
      TYPES = Registry::TYPES
      ALL = :all

      # A family whose extractor already publishes its internal relationships
      # (`type_reference`/`field_resolver`). A second `code_reference` edge
      # inside the family would only duplicate those.
      #
      # Components are not kept apart (LOS-123): a component that constructs
      # another and passes it on (`Wrapper.new(primary: Kit::Button.new)`)
      # has no other edge to it, and {Pass} leaves out the reference a
      # `render` or `slot` edge already states, so a rendered component is
      # not linked twice.
      GRAPHQL_TYPES = %i[graphql_type graphql_mutation graphql_resolver graphql_query].freeze

      # Caller type to the target types it may reference.
      DEFAULTS = TYPES.to_h { |type| [type, ALL] }
                      .merge(GRAPHQL_TYPES.to_h { |type| [type, (TYPES - GRAPHQL_TYPES).freeze] }).freeze

      class << self
        # @param overrides [Hash, nil] caller type to +:all+, +false+ or target types
        # @return [Hash{Symbol => Array<Symbol>}] frozen map covering every registry type
        # @raise [Woods::ConfigurationError] for an unknown type or malformed entry
        def normalize(overrides)
          overrides ||= {}
          unless overrides.is_a?(Hash)
            raise ConfigurationError, "source_reference_callers must be a Hash, got #{overrides.inspect}"
          end

          merged = DEFAULTS.merge(overrides.to_h { |caller, targets| [caller_type!(caller), targets] })
          TYPES.to_h { |caller| [caller, targets!(caller, merged[caller])] }.freeze
        end

        private

        def caller_type!(caller)
          type = symbol(caller)
          return type if TYPES.include?(type)

          raise ConfigurationError, "source_reference_callers has unknown caller type #{caller.inspect}; " \
                                    "valid types: #{TYPES.join(', ')}"
        end

        def targets!(caller, targets)
          return TYPES if [ALL, ALL.to_s, true].include?(targets)
          return [].freeze if targets.nil? || targets == false

          unless targets.is_a?(Array)
            raise ConfigurationError, "source_reference_callers for #{caller} must be :all, false or an Array, " \
                                      "got #{targets.inspect}"
          end

          targets.map { |target| target_type!(caller, target) }.uniq.sort.freeze
        end

        def target_type!(caller, target)
          type = symbol(target)
          return type if TYPES.include?(type)

          raise ConfigurationError, "source_reference_callers has unknown target type #{target.inspect} " \
                                    "for #{caller}; valid types: #{TYPES.join(', ')}"
        end

        def symbol(value)
          value.respond_to?(:to_sym) ? value.to_sym : value
        end
      end

      # @param overrides [Hash, nil] entries replacing the matching {DEFAULTS} entries
      # @raise [Woods::ConfigurationError] for an unknown type or malformed entry
      def initialize(overrides = nil)
        @targets = self.class.normalize(overrides).each_with_object({}) do |(caller, targets), map|
          map[caller.to_s] = targets.to_set(&:to_s) unless targets.empty?
        end
      end

      # @param type [String, Symbol, nil] unit type
      # @return [Boolean] whether units of this type publish reference edges
      def caller?(type)
        @targets.key?(type.to_s)
      end

      # @param caller [String, Symbol] caller unit type
      # @param target [String, Symbol] resolved target unit type
      # @return [Boolean] whether the caller may publish an edge to that type
      def permits?(caller, target)
        @targets[caller.to_s]&.include?(target.to_s) || false
      end

      # @return [Hash{String => Array<String>}] sorted, JSON-stable callers
      def to_h
        @targets.keys.sort.to_h { |caller| [caller, @targets.fetch(caller).sort] }
      end
    end
  end
end
