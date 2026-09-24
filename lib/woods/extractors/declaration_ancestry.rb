# frozen_string_literal: true

require_relative 'class_declarations'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Runtime qualification belongs to the selected class and its actual source.
    # An unavailable class may use limited declaration evidence; a foreign one
    # must never lend its ancestry to a same-named file.
    class DeclarationAncestry
      SOURCE_LOCATION = Module.instance_method(:const_source_location)

      # @param source [String] original source, never evaluated
      # @param identifier [String] selected extraction identity
      # @param file_path [String] source file owning the unit
      def initialize(source:, identifier:, file_path:)
        @lookup = SourceReferences::RuntimeLookup.new
        @declaration = declaration(source, identifier)
        result = @lookup.call("::#{identifier}", allow_private: true)
        @runtime = result[:value] if result[:status] == :resolved
        @foreign = if @runtime
                     !owned_class?(identifier, file_path)
                   else
                     result[:status] == :unknown && !%w[autoload_pending unloaded_scope].include?(result[:reason])
                   end
        @names = ancestry_names(@runtime) if @runtime && !@foreign
      end

      # @return [Boolean] whether this file can qualify as a delegator
      def manager?
        return false if @foreign
        return @names.include?('Delegator') if @names

        %w[SimpleDelegator Delegator].include?(parent_name&.delete_prefix('::')) || delegate_class? ||
          @declaration&.fetch(:source)&.match?(/include\s+(?:::)?Delegator\b/) || false
      end

      # @return [Symbol] supported delegation metadata, without running a factory
      def delegation_type
        return :simple_delegator if @names&.include?('SimpleDelegator')
        return :simple_delegator if !@names && parent_name&.delete_prefix('::') == 'SimpleDelegator'
        return :delegate_class if delegate_class?

        :unknown
      end

      # @return [Boolean] whether a loaded class belongs to another file
      def foreign?
        !!@foreign
      end

      # @return [Boolean] conventional ApplicationPolicy ancestry
      def application_policy?
        return false if @foreign
        return @names.drop(1).any? { |name| name.split('::').last == 'ApplicationPolicy' } if @names

        parent_name&.split('::')&.last == 'ApplicationPolicy'
      end

      private

      def declaration(source, identifier)
        ClassDeclarations.read(source).find { |record| record[:identifier] == identifier }
      rescue ClassDeclarations::Unresolved
        # Missing static evidence must not suppress independently owned runtime
        # ancestry or change the generic policy extractor's emission policy.
        nil
      end

      def parent_name
        ClassDeclarations.parent_name(@declaration) if @declaration
      end

      def delegate_class?
        parent = @declaration&.fetch(:node)&.superclass
        parent.is_a?(Prism::CallNode) && parent.name == :DelegateClass && parent.receiver.nil?
      end

      def owned_class?(identifier, path)
        return false unless @lookup.class_object?(@runtime)

        location = SOURCE_LOCATION.bind(Object).call(identifier, false)
        location && File.expand_path(location.first) == File.expand_path(path)
      end

      def ancestry_names(klass)
        @lookup.reflect(klass, :ancestors).filter_map { |ancestor| @lookup.reflect(ancestor, :name) }
      end
    end
  end
end
