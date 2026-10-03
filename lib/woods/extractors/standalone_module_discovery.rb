# frozen_string_literal: true

require 'set'
require_relative '../source_references/runtime_lookup'
require_relative 'concern_extractor'
require_relative 'module_def_sites'
require_relative '../path_dispatcher'

module Woods
  module Extractors
    # Discovers modules whose canonical declaration and own behavior or data
    # live in a file the PORO extractor scans ({PathDispatcher.poro_path?}). It does not autoload constants or invoke application
    # methods. Cross-file reopenings deliberately do not become additional
    # source owners.
    class StandaloneModuleDiscovery
      CORE_SINGLETON = Object.instance_method(:singleton_class)
      CORE_SOURCE = Module.instance_method(:const_source_location)
      CORE_METHOD = Module.instance_method(:instance_method)
      CORE_OWNER = UnboundMethod.instance_method(:owner)
      CORE_LOCATION = UnboundMethod.instance_method(:source_location)
      CORE_SUPER = UnboundMethod.instance_method(:super_method)
      CORE_IS_A = Kernel.instance_method(:is_a?)
      CORE_IVAR_DEFINED = Kernel.instance_method(:instance_variable_defined?)
      CORE_CONSTANTS = Module.instance_method(:constants)
      CORE_CONST_DEFINED = Module.instance_method(:const_defined?)
      CORE_CONST_GET = Module.instance_method(:const_get)
      CORE_AUTOLOAD = Module.instance_method(:autoload?)
      VISIBILITIES = %i[public protected private].freeze
      CORE_LISTS = VISIBILITIES.to_h { |visibility| [visibility, Module.instance_method("#{visibility}_instance_methods")] }
                               .freeze
      # Hooks ActiveSupport::Concern stores on its module; either one is behavior.
      CONCERN_BLOCKS = %i[@_included_block @_prepended_block].freeze

      def initialize(root: Rails.root, concerns: ConcernExtractor.new)
        @root = File.expand_path(root)
        @lookup = SourceReferences::RuntimeLookup.new
        @concerns = concerns
      end

      # @param path [String] original application source path
      # @param analysis [Hash] SourceReferences::Collector result for this file
      # @param admit [Boolean] accept a path another extractor owns (owner fallback)
      # @return [Array<Hash>] canonical identifiers and source-verified method metadata
      def call(path, analysis:, admit: false)
        return [] unless admit ? under_root?(path) : eligible_path?(path)

        declarations = analysis.fetch('declarations').select do |declaration|
          declaration['kind'] == 'module' && declaration.fetch('singleton_depth', 0).zero?
        end
        declarations.group_by { |declaration| declaration['owner'] }.filter_map do |identifier, candidates|
          next if claimed_identity?(identifier)

          value = verified_constant(identifier, candidates, path, kind: :module)
          next unless value

          module_record(identifier, value, path, candidates)
        end
      end

      # @param identifier [String] constant path
      # @param path [String] application source path
      # @return [Boolean] whether +path+ is the constant's canonical declaration
      def owns?(identifier, path)
        canonical_path(identifier) == File.realpath(path)
      end

      # Classes this file declares and canonically owns.
      #
      # @param path [String] original application source path
      # @param declarations [Array<Hash>] collector class declarations to verify
      # @return [Array<String>] verified class identifiers, in declaration order
      def owned_classes(path, declarations)
        declarations.group_by { |declaration| declaration['owner'] }.filter_map do |identifier, candidates|
          identifier if verified_constant(identifier, candidates, path, kind: :class)
        end
      end

      private

      # A module counts when it has behavior or data of its own: methods, an
      # ActiveSupport::Concern hook or ClassMethods, or non-module constants.
      def module_record(identifier, value, path, candidates)
        methods = own_methods(value, path, candidates)
        concern = concern_class_methods(value, path, candidates)
        constants = own_constants(value, path, candidates)
        return if methods[:all].empty? && concern.nil? && constants.empty?

        record = { identifier: identifier, public_methods: methods[:public],
                   class_methods: (methods[:singleton] + concern.to_a).uniq.sort,
                   method_count: methods[:all].size + concern.to_a.size }
        record[:active_support_concern] = true if concern
        record[:constants] = constants unless constants.empty?
        record
      end

      # @return [Array<String>, nil] ClassMethods names, or nil when the module
      #   is not a concern with any hook or class method of its own
      def concern_class_methods(value, path, declarations)
        return unless defined?(ActiveSupport::Concern) && CORE_IS_A.bind(value).call(ActiveSupport::Concern)

        class_methods = class_methods_module(value)
        names = class_methods ? methods_at(class_methods, path, declarations).values.flat_map(&:keys) : []
        hooked = CONCERN_BLOCKS.any? { |ivar| CORE_IVAR_DEFINED.bind(value).call(ivar) }
        names.uniq.sort if hooked || names.any?
      end

      def class_methods_module(value)
        return unless CORE_CONST_DEFINED.bind(value).call(:ClassMethods, false)
        return if CORE_AUTOLOAD.bind(value).call(:ClassMethods, false)

        candidate = CORE_CONST_GET.bind(value).call(:ClassMethods, false)
        candidate if @lookup.module_object?(candidate) && !@lookup.class_object?(candidate)
      end

      def own_constants(value, path, declarations)
        CORE_CONSTANTS.bind(value).call(false).filter_map do |name|
          next if CORE_AUTOLOAD.bind(value).call(name, false)
          next unless local_method?(CORE_SOURCE.bind(value).call(name, false), path, declarations)
          next if @lookup.module_object?(CORE_CONST_GET.bind(value).call(name, false))

          name.to_s
        end.sort
      end

      def eligible_path?(path)
        absolute = File.expand_path(path, @root)
        return false unless absolute.start_with?("#{@root}/")

        real_root = File.realpath(@root)
        real = File.realpath(absolute)
        real.start_with?("#{real_root}/") && PathDispatcher.poro_path?(real.delete_prefix("#{real_root}/"))
      end

      def under_root?(path)
        real = File.realpath(File.expand_path(path, @root))
        real.end_with?('.rb') && real.start_with?("#{File.realpath(@root)}/")
      end

      def claimed_identity?(identifier)
        @claimed ||= @concerns.runtime_model_mixins.values.flatten.to_set do |mod|
          @lookup.reflect(mod, :name)
        end
        @claimed.include?(identifier)
      end

      def verified_constant(identifier, declarations, path, kind:)
        declarations.each do |declaration|
          result = @lookup.call(declaration['name'], nesting: declaration.fetch('enclosing_nesting', []),
                                                     allow_private: true)
          value = result[:value]
          next unless result[:status] == :resolved && result[:target] == identifier
          next unless @lookup.class_object?(value) == (kind == :class)
          next unless canonical_path(identifier) == File.realpath(path)

          return value
        end
        nil
      end

      def canonical_path(identifier)
        parts = identifier.split('::')
        name = parts.pop
        scope = parts.empty? ? Object : @lookup.call("::#{parts.join('::')}", allow_private: true)[:value]
        return unless @lookup.module_object?(scope)

        location = CORE_SOURCE.bind(scope).call(name, false)
        file = location_file(location)
        File.realpath(file) if file
      end

      def own_methods(value, path, declarations)
        instance = methods_at(value, path, declarations)
        singleton = methods_at(CORE_SINGLETON.bind(value).call, path, declarations)
        all = (instance.values.flat_map(&:to_a) + singleton.values.flat_map(&:to_a)).uniq
        { public: instance.fetch(:public).keys.sort, singleton: singleton.fetch(:public).keys.sort, all: all }
      end

      def methods_at(scope, path, declarations)
        VISIBILITIES.to_h do |visibility|
          methods = CORE_LISTS.fetch(visibility).bind(scope).call(false).filter_map do |name|
            method = own_definition(CORE_METHOD.bind(scope).call(name), scope)
            next unless method

            location = CORE_LOCATION.bind(method).call
            next unless local_method?(location, path, declarations) || declared_here?(name, path, declarations)

            [name.to_s, location]
          end
          [visibility, methods.to_h]
        end
      end

      # A prepended wrapper (a memoizer) answers first; the scope's own
      # definition sits behind it in the super chain.
      def own_definition(method, scope)
        while method
          return method if SourceReferences::RuntimeLookup::CORE_EQUAL.bind(CORE_OWNER.bind(method).call).call(scope)

          method = CORE_SUPER.bind(method).call
        end
      end

      # A helper in another file can redefine a method in place, which moves its
      # runtime location; the `def` in this file's module body still owns it.
      def declared_here?(name, path, declarations)
        lines = declarations.map { |declaration| declaration['line'] }
        @def_sites ||= {}
        @def_sites[[path, lines]] ||= ModuleDefSites.new(File.read(path)).call(lines)
        @def_sites[[path, lines]].include?(name.to_s)
      end

      # Ruby 3.1 can report a constant location as [false, 0]; only a String
      # naming an existing file is a location.
      #
      # @return [String, nil]
      def location_file(location)
        file = location.is_a?(Array) ? location.first : nil
        file if file.is_a?(String) && File.file?(file)
      end

      def local_method?(location, path, declarations)
        file = location_file(location)
        return false unless file && File.realpath(file) == File.realpath(path)

        declarations.any? { |declaration| (declaration['line']..declaration['end_line']).cover?(location.last) }
      end
    end
  end
end
