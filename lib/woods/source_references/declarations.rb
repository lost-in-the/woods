# frozen_string_literal: true

require_relative 'collector'

module Woods
  module SourceReferences
    # Declaration spans (#751): the literal symbol of an association, callback
    # or scope macro in a class body, published only where the unit's runtime
    # metadata confirms the declaration. Associations point at their target
    # model through the typed registry; callbacks and scopes point at the
    # declaring unit with the method they name. They are spans only and add
    # no dependency: the extractors already publish association edges.
    class Declarations
      # @param unit [Hash] string-keyed unit, metadata included
      # @param registry [Registry]
      # @param policy [CallerPolicy]
      def initialize(unit, registry, policy)
        @unit = unit
        @metadata = unit['metadata'] || {}
        @registry = registry
        @policy = policy
      end

      # @param macros [Array<Hash>] collected macro records owned by the unit
      # @param path [String] the source they were collected from
      # @return [Array<Array(nil, Hash)>] occurrences in the pass's [edge, span] form
      def call(macros, path)
        macros.filter_map do |record|
          span = span_for(record)
          [nil, record.slice('line', 'column', 'length').merge('file_path' => path, **span)] if span
        end
      end

      private

      def span_for(record)
        name = record['name']
        macro = record['macro']
        return association(macro, name) if Collector::ASSOCIATION_MACROS.include?(macro)
        return (own_method('scope', name) if scope?(name)) if macro == 'scope'

        own_method('callback_method', name) if callback?(name)
      end

      # Runtime reflection names the target class; the registry gives its type.
      def association(macro, name)
        target = association_target(macro, name)
        return unless target

        types = @registry.typed_targets(target).select { |type| @policy.permits?(@unit['type'], type.to_sym) }
        return if types.empty?

        if types.one?
          return { 'target' => target, 'target_type' => types.first, 'kind' => 'association',
                   'confidence' => 'verified' }
        end

        { 'kind' => 'association', 'confidence' => 'ambiguous',
          'candidates' => types.map { |type| { 'target' => target, 'target_type' => type } } }
      end

      # The reflected target class of a non-polymorphic association of this macro and name.
      def association_target(macro, name)
        association = Array(@metadata['associations']).find do |record|
          record['name'].to_s == name && record['type'].to_s == macro
        end
        target = association && !association['polymorphic'] && association['target']
        target.delete_prefix('::') if target.is_a?(String)
      end

      def own_method(kind, name)
        { 'target' => @unit['identifier'], 'target_type' => @unit['type'], 'kind' => kind,
          'confidence' => 'verified', 'method' => name }
      end

      # The resolved chain lists the method: model callbacks and controller filters.
      def callback?(name)
        (Array(@metadata['callbacks']) + Array(@metadata['filters'])).any? do |record|
          record.is_a?(Hash) && record['filter'].to_s == name
        end
      end

      def scope?(name)
        Array(@metadata['scopes']).any? do |scope|
          (scope.is_a?(Hash) ? scope['name'] : scope).to_s == name
        end
      end
    end
  end
end
