# frozen_string_literal: true

require_relative '../source_references/runtime_lookup'
require_relative 'phlex_extractor'
require_relative 'serializer_extractor'

module Woods
  module Extractors
    # Base classes whose descendants an extractor discovers at runtime rather
    # than by path. The PORO sweep never emits a class one of these owns,
    # whatever directory declares it.
    #
    # Ancestry is a superset of each extractor's `discoverable_classes` (those
    # filter descendants further), so the sweep cannot duplicate a typed unit.
    # It is a property of the constant alone, so full and incremental runs
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
        jobs: %w[ActiveJob::Base Sidekiq::Job Sidekiq::Worker],
        serializers: SerializerExtractor::BASE_CLASSES.keys,
        graphql: %w[GraphQL::Schema::Member]
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
        nil
      end
    end
  end
end
