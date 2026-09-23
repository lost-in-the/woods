# frozen_string_literal: true

module Woods
  module SourceReferences
    # Reads already-loaded constant tables without invoking application overrides,
    # const_missing, or an autoload. Results are scoped to one extraction run.
    class RuntimeLookup
      CORE_TYPE = Module.instance_method(:===)
      CORE_EQUAL = BasicObject.instance_method(:equal?)
      CONSTANT = /\A(?:::)?[[:upper:]][[:word:]]*(?:::[[:upper:]][[:word:]]*)*\z/
      REFLECTION = %i[const_defined? const_get autoload? ancestors name constants].to_h do |method|
        [method, Module.instance_method(method)]
      end.freeze

      # @param name [String] a literal constant path
      # @param nesting [Array<String>] lexical scopes, innermost first
      # @return [Hash] lookup status and canonical target or unresolved reason
      def call(name, nesting: [], allow_private: false)
        return unknown('invalid_constant') unless valid_name?(name)

        parts = name.delete_prefix('::').split('::')
        scopes = name.start_with?('::') ? { scopes: [Object] } : lexical_scopes(nesting)
        return scopes unless scopes[:scopes]

        result = first_constant(scopes[:scopes], parts.shift, public_only: name.start_with?('::') && !allow_private)
        parts.each do |part|
          return result unless module_object?(result[:value])

          result = first_constant(qualified_scopes(result[:value]), part, public_only: !allow_private)
        end
        result
      end

      # @param scope [Module] runtime module to inspect
      # @param method [Symbol] one of the bound core reflection methods
      # @return [Object] core reflection result
      def reflect(scope, method, *args)
        REFLECTION.fetch(method).bind(scope).call(*args)
      end

      # @return [Boolean] core class/module checks that cannot dispatch to application overrides
      def module_object?(value)
        CORE_TYPE.bind(Module).call(value)
      end

      # @return [Boolean] whether a runtime object is a class
      def class_object?(value)
        CORE_TYPE.bind(Class).call(value)
      end

      private

      def valid_name?(name)
        name.is_a?(String) && CONSTANT.match?(name)
      end

      def identical?(left, right)
        CORE_EQUAL.bind(left).call(right)
      end

      def qualified_scopes(receiver)
        ancestors = reflect(receiver, :ancestors)
        return [receiver, *ancestors] if identical?(receiver, Object)

        [receiver, *ancestors.take_while { |ancestor| !identical?(ancestor, Object) }]
      end

      def lexical_scopes(nesting)
        return { scopes: [Object] } if nesting.empty?

        modules = nesting.map do |name|
          result = call("::#{name}", allow_private: true)
          return unknown('unloaded_scope') unless module_object?(result[:value])

          result[:value]
        end
        ancestors = reflect(modules.first, :ancestors)
        ancestors += [Object] unless class_object?(modules.first)
        { scopes: modules + ancestors }
      end

      def first_constant(scopes, name, public_only: false)
        scopes.each do |scope|
          next unless reflect(scope, :const_defined?, name, false)
          return unknown('private_constant') if private_access?(scope, name, public_only)
          return unknown('autoload_pending') if reflect(scope, :autoload?, name, false)

          return constant_value(scope, name)
        end
        { status: :missing, reason: 'constant_missing', root_lookup: scopes.any? { |scope| identical?(scope, Object) } }
      rescue NameError
        unknown('constant_changed')
      end

      def private_access?(scope, name, public_only)
        public_only && !reflect(scope, :constants, false).include?(name.to_sym)
      end

      def constant_value(scope, name)
        value = reflect(scope, :const_get, name, false)
        return unknown('non_module_constant') unless module_object?(value)

        canonical = reflect(value, :name)
        namespace = identical?(scope, Object) ? nil : reflect(scope, :name)
        expected = [namespace, name].compact.join('::')
        return unknown('constant_alias') unless canonical == expected

        { status: :resolved, target: canonical, value: value }
      end

      def unknown(reason)
        { status: :unknown, reason: reason }
      end
    end
  end
end
