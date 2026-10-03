# frozen_string_literal: true

require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # The one rule for "the graphql extractor owns this class", shared by
    # {GraphQLExtractor} and {ClassFamilies} so the PORO sweep and fallback
    # never disagree with it. Batch loaders, custom fields, and a
    # superclass-less `Resolvers::Base` are not admitted, so they stay PORO.
    module GraphQLAncestry
      # graphql-ruby schema bases whose descendants are GraphQL units.
      SCHEMA_BASES = %i[Object InputObject Enum Union Scalar Mutation Resolver Interface].freeze

      module_function

      # @param klass [Module] loaded constant
      # @param lookup [SourceReferences::RuntimeLookup]
      # @return [Boolean]
      def admitted?(klass, lookup = SourceReferences::RuntimeLookup.new)
        schema_class?(klass, lookup) || resolver_helper?(klass, lookup)
      end

      # @return [Boolean] a schema, or a descendant of a graphql-ruby schema base
      def schema_class?(klass, lookup)
        return false unless defined?(GraphQL::Schema) && lookup.module_object?(klass)

        ancestors = lookup.reflect(klass, :ancestors)
        return true if ancestors.include?(GraphQL::Schema) && klass != GraphQL::Schema

        SCHEMA_BASES.any? do |name|
          GraphQL::Schema.const_defined?(name, false) && ancestors.include?(GraphQL::Schema.const_get(name, false))
        end
      end

      # Older file discovery admitted ordinary Resolvers::Base subclasses.
      # Verify real inheritance; directory names are not evidence.
      #
      # @return [Boolean]
      def resolver_helper?(klass, lookup)
        return false unless lookup.class_object?(klass)

        result = lookup.call('::Resolvers::Base', allow_private: true)
        base = result[:value] if result[:status] == :resolved
        return false unless lookup.class_object?(base)

        lookup.reflect(klass, :ancestors).drop(1).any? do |ancestor|
          SourceReferences::RuntimeLookup::CORE_EQUAL.bind(ancestor).call(base)
        end
      end
    end
  end
end
