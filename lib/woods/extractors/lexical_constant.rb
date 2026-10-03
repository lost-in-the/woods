# frozen_string_literal: true

module Woods
  module Extractors
    # Resolves a constant reference the way Ruby does at its call site, against
    # the constants the booted application has loaded.
    #
    # The lookup order is Ruby's: each lexical scope's own constants,
    # innermost first; then the innermost scope's ancestors; then the top
    # level. The answer is the found constant's own `name`, never the
    # candidate string. `Shipment.const_get(:PingJob)` returns a top-level
    # `PingJob` through `Object`, and calling that `Shipment::PingJob` would
    # name a constant that does not exist.
    module LexicalConstant
      # A constant segment starts with an uppercase letter.
      CONSTANT_HEAD = /\A[[:upper:]]/

      module_function

      # @param reference [String] the constant as written (`PingJob`,
      #   `Tasks::PingJob`)
      # @param nesting [Array<String>] enclosing scope names, innermost first
      # @param modules [Hash{String => Module, nil}] memo of scope lookups,
      #   shared across the references of one source
      # @return [String] the resolved constant's name, or +reference+ when it
      #   resolves to nothing loaded
      def resolve(reference, nesting, modules: {})
        head, rest = reference.split('::', 2)
        return reference unless head.match?(CONSTANT_HEAD)

        crefs = nesting.filter_map do |name|
          modules.key?(name) ? modules[name] : modules[name] = loaded_module(name)
        end
        return reference if crefs.empty?

        found = lookup(head, crefs)
        found = scoped(found, rest) if found && rest
        found.is_a?(Module) && found.name ? found.name : reference
      rescue StandardError, ScriptError
        reference
      end

      # @return [Object, nil] what +head+ names in the innermost of +crefs+
      def lookup(head, crefs)
        owner = crefs.find { |mod| mod.const_defined?(head, false) }
        return owner.const_get(head, false) if owner

        crefs.first.const_get(head) if crefs.first.const_defined?(head)
      end

      # `A::B` reads B from A and A's ancestors, never from the top level.
      #
      # @return [Module, nil]
      def scoped(mod, path)
        path.split('::').reduce(mod) do |scope, segment|
          return nil unless scope.is_a?(Module)

          owner = scope.ancestors.find do |ancestor|
            !TOP_LEVEL.include?(ancestor) && ancestor.const_defined?(segment, false)
          end
          return nil unless owner

          owner.const_get(segment, false)
        end
      end

      # Ancestors whose constants a scoped `A::B` lookup does not reach.
      TOP_LEVEL = [Object, Kernel, BasicObject].freeze

      # @param name [String] a scope name as written
      # @return [Module, nil] the loaded module of that exact name
      def loaded_module(name)
        return nil unless Object.const_defined?(name)

        mod = Object.const_get(name)
        mod.is_a?(Module) && mod.name == name ? mod : nil
      rescue StandardError, ScriptError
        nil
      end

      private_class_method :lookup, :scoped, :loaded_module
    end
  end
end
