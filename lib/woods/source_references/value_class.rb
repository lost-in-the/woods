# frozen_string_literal: true

require_relative 'runtime_lookup'

module Woods
  module SourceReferences
    # Verifies literal value-class assignment evidence against loaded Ruby state.
    # Bound core methods avoid application reflection overrides and never run a
    # constructor, autoload, const_missing, or an application method body.
    class ValueClass
      SOURCE_LOCATION = Module.instance_method(:const_source_location)
      SINGLETON_CLASS = Object.instance_method(:singleton_class)
      INSTANCE_METHOD = Module.instance_method(:instance_method)
      METHOD_OWNER = UnboundMethod.instance_method(:owner)
      METHOD_SOURCE = UnboundMethod.instance_method(:source_location)

      def initialize
        @lookup = RuntimeLookup.new
      end

      # @param declaration [Hash] collector declaration with a literal constructor
      # @param file_path [String] original file containing the assignment
      # @return [String, nil] canonical, source-owned class identity
      def call(declaration, file_path:)
        return unless candidate?(declaration)

        factory = factory(declaration)
        return unless factory

        result = @lookup.call(declaration['name'], nesting: declaration['enclosing_nesting'], allow_private: true)
        return unless value_class?(result, declaration, factory)
        return unless owns_assignment?(result[:target], declaration, file_path)

        result[:target]
      rescue NameError, TypeError, ArgumentError
        nil
      end

      private

      def candidate?(declaration)
        declaration['constructor'] && declaration.fetch('singleton_depth', 0).zero?
      end

      def value_class?(result, declaration, factory)
        result[:target] == declaration['owner'] && @lookup.class_object?(result[:value]) &&
          @lookup.reflect(result[:value], :ancestors).any? { |ancestor| identical?(ancestor, factory) }
      end

      def factory(declaration)
        name = declaration['constructor']
        core_name = name.delete_prefix('::')
        return unless %w[Struct Data].include?(core_name)

        actual = @lookup.call(name, nesting: declaration['enclosing_nesting'])[:value]
        core = @lookup.call("::#{core_name}")[:value]
        return unless core && identical?(actual, core)

        singleton = SINGLETON_CLASS.bind(core).call
        method = INSTANCE_METHOD.bind(singleton).call(core_name == 'Struct' ? :new : :define)
        return unless identical?(METHOD_OWNER.bind(method).call, singleton) && METHOD_SOURCE.bind(method).call.nil?

        core
      end

      def owns_assignment?(identifier, declaration, file_path)
        parts = identifier.split('::')
        name = parts.pop
        scope = parts.empty? ? Object : @lookup.call("::#{parts.join('::')}", allow_private: true)[:value]
        return false unless @lookup.module_object?(scope)

        location = SOURCE_LOCATION.bind(scope).call(name, false)
        location && File.expand_path(location.first) == File.expand_path(file_path) &&
          location.last.between?(declaration['line'], declaration['end_line'])
      end

      def identical?(left, right)
        RuntimeLookup::CORE_EQUAL.bind(left).call(right)
      end
    end
  end
end
