# frozen_string_literal: true

require 'set'
require_relative '../source_references/runtime_lookup'
require_relative 'concern_extractor'

module Woods
  module Extractors
    # Discovers callable modules whose canonical declaration and own methods live
    # in app/models. It does not autoload constants or invoke application methods.
    # Cross-file reopenings deliberately do not become additional source owners.
    class StandaloneModuleDiscovery
      CORE_SINGLETON = Object.instance_method(:singleton_class)
      CORE_SOURCE = Module.instance_method(:const_source_location)
      CORE_METHOD = Module.instance_method(:instance_method)
      CORE_OWNER = UnboundMethod.instance_method(:owner)
      CORE_LOCATION = UnboundMethod.instance_method(:source_location)
      VISIBILITIES = %i[public protected private].freeze
      CORE_LISTS = VISIBILITIES.to_h { |visibility| [visibility, Module.instance_method("#{visibility}_instance_methods")] }
                               .freeze

      def initialize(root: Rails.root, concerns: ConcernExtractor.new)
        @root = File.expand_path(root)
        @lookup = SourceReferences::RuntimeLookup.new
        @concerns = concerns
      end

      # @param path [String] original application source path
      # @param analysis [Hash] SourceReferences::Collector result for this file
      # @return [Array<Hash>] canonical identifiers and source-verified method metadata
      def call(path, analysis:)
        return [] unless eligible_path?(path)

        declarations = analysis.fetch('declarations').select do |declaration|
          declaration['kind'] == 'module' && declaration.fetch('singleton_depth', 0).zero?
        end
        declarations.group_by { |declaration| declaration['owner'] }.filter_map do |identifier, candidates|
          next if claimed_identity?(identifier)

          value = verified_module(identifier, candidates, path)
          next unless value

          methods = own_methods(value, path, candidates)
          next if methods[:all].empty?

          { identifier: identifier, public_methods: methods[:public], class_methods: methods[:singleton],
            method_count: methods[:all].size }
        end
      end

      private

      def eligible_path?(path)
        absolute = File.expand_path(path, @root)
        return false unless absolute.start_with?("#{@root}/app/models/") && absolute.end_with?('.rb')
        return false if absolute.include?('/concerns/')

        File.realpath(absolute).start_with?("#{File.realpath(@root)}/app/models/")
      end

      def claimed_identity?(identifier)
        @claimed ||= @concerns.runtime_model_mixins.values.flatten.to_set do |mod|
          @lookup.reflect(mod, :name)
        end
        @claimed.include?(identifier)
      end

      def verified_module(identifier, declarations, path)
        declarations.each do |declaration|
          result = @lookup.call(declaration['name'], nesting: declaration.fetch('enclosing_nesting', []),
                                                     allow_private: true)
          value = result[:value]
          next unless result[:status] == :resolved && result[:target] == identifier
          next if @lookup.class_object?(value)
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
        File.realpath(location.first) if location && File.file?(location.first)
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
            method = CORE_METHOD.bind(scope).call(name)
            next unless SourceReferences::RuntimeLookup::CORE_EQUAL.bind(CORE_OWNER.bind(method).call).call(scope)

            location = CORE_LOCATION.bind(method).call
            next unless local_method?(location, path, declarations)

            [name.to_s, location]
          end
          [visibility, methods.to_h]
        end
      end

      def local_method?(location, path, declarations)
        unless location && File.file?(location.first) && File.realpath(location.first) == File.realpath(path)
          return false
        end

        declarations.any? { |declaration| (declaration['line']..declaration['end_line']).cover?(location.last) }
      end
    end
  end
end
