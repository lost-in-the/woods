# frozen_string_literal: true

require_relative '../source_references/runtime_lookup'
require_relative 'phlex_extractor'
require_relative 'serializer_extractor'
require_relative 'graphql_ancestry'
require_relative 'job_ancestry'

module Woods
  module Extractors
    # Base classes whose descendants an extractor discovers at runtime rather
    # than by path. The PORO sweep never emits a class one of these owns,
    # whatever directory declares it.
    #
    # For base-class families, ancestry is a superset of the extractor's
    # `discoverable_classes`, so the sweep cannot duplicate a typed unit. Jobs
    # and GraphQL use the predicate their own extractor admits by. Either way
    # the answer depends on the constant alone, so full and incremental runs
    # agree without reading any extractor's output.
    module ClassFamilies
      # Extractor key => base constant names, checked in order.
      BASES = {
        models: %w[ActiveRecord::Base],
        controllers: %w[ActionController::Base ActionController::API ActionController::Metal],
        mailers: %w[ActionMailer::Base],
        action_cable_channels: %w[ActionCable::Channel::Base],
        view_components: %w[ViewComponent::Base ViewComponent::Preview],
        components: PhlexExtractor::PHLEX_BASES,
        serializers: SerializerExtractor::BASE_CLASSES.keys
      }.freeze

      # Extractor key => the predicate that extractor itself uses to admit a class.
      PREDICATES = {
        graphql: ->(klass, lookup) { GraphQLAncestry.admitted?(klass, lookup) },
        jobs: ->(klass, _lookup) { JobAncestry.admitted?(klass, app_root: Rails.root.to_s) }
      }.freeze

      CORE_LE = Module.instance_method(:<=)

      module_function

      # @param klass [Class] a loaded application class
      # @param lookup [SourceReferences::RuntimeLookup]
      # @return [Symbol, nil] the extractor key that owns +klass+, if any
      def owner_of(klass, lookup = SourceReferences::RuntimeLookup.new)
        BASES.each do |key, names|
          names.each do |name|
            base = lookup.call("::#{name}")[:value]
            return key if lookup.module_object?(base) && CORE_LE.bind(klass).call(base)
          end
        end
        PREDICATES.find { |_key, admitted| admitted.call(klass, lookup) }&.first
      end
    end
  end
end
