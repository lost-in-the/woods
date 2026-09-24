# frozen_string_literal: true

require_relative '../source_references/value_class'

module Woods
  module Extractors
    # Selects the source-owned value class instead of its reopening namespace.
    class AssignedValueDiscovery
      CORE_METHODS = Module.instance_method(:instance_methods)
      CORE_PRIVATE_METHODS = Module.instance_method(:private_instance_methods)

      # @param file_path [String] original Ruby file
      # @param analysis [Hash] original-source Collector result
      # @param expected [String, nil] active loader's expected constant identity
      # @param preserve_modules [Boolean] retain a canonical library module primary
      # @return [String, nil] verified assigned child, or nil to preserve ordinary discovery
      def call(file_path, analysis:, expected: nil, preserve_modules: false)
        return if analysis['parse_error']

        verifier = SourceReferences::ValueClass.new
        declarations = analysis.fetch('declarations')
        candidates = declarations.filter_map { |record| verifier.call(record, file_path: file_path) }
        return expected if candidates.include?(expected)
        return if candidates.empty? || owns_primary?(declarations, file_path, expected, preserve_modules)

        candidates.first
      end

      private

      def owns_primary?(declarations, file_path, expected, preserve_modules)
        lookup = SourceReferences::RuntimeLookup.new
        declarations.any? do |record|
          next false if record['constructor'] || record.fetch('singleton_depth', 0).positive?
          next false unless canonical_file?(record['owner'], file_path, lookup)
          next true if record['kind'] == 'class'
          next false unless preserve_modules

          record['owner'] == expected || callable_module?(record['owner'], file_path, lookup)
        end
      end

      def canonical_file?(identifier, file_path, lookup)
        parts = identifier.split('::')
        name = parts.pop
        scope = parts.empty? ? Object : lookup.call("::#{parts.join('::')}", allow_private: true)[:value]
        return false unless lookup.module_object?(scope)

        location = SourceReferences::ValueClass::SOURCE_LOCATION.bind(scope).call(name, false)
        location&.first && File.expand_path(location.first) == File.expand_path(file_path)
      end

      def callable_module?(identifier, path, lookup)
        value = lookup.call("::#{identifier}", allow_private: true)[:value]
        return false unless lookup.module_object?(value)

        singleton = SourceReferences::ValueClass::SINGLETON_CLASS.bind(value).call
        [value, singleton].any? { |scope| own_method_at?(scope, path) }
      end

      def own_method_at?(scope, path)
        names = CORE_METHODS.bind(scope).call(false) + CORE_PRIVATE_METHODS.bind(scope).call(false)
        names.any? do |name|
          method = SourceReferences::ValueClass::INSTANCE_METHOD.bind(scope).call(name)
          owner = SourceReferences::ValueClass::METHOD_OWNER.bind(method).call
          next false unless SourceReferences::RuntimeLookup::CORE_EQUAL.bind(owner).call(scope)

          location = SourceReferences::ValueClass::METHOD_SOURCE.bind(method).call
          location && File.expand_path(location.first) == File.expand_path(path)
        end
      end
    end
  end
end
