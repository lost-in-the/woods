# frozen_string_literal: true

require 'pathname'
require_relative 'runtime_lookup'

module Woods
  module SourceReferences
    # Maps verified source declarations to extracted constant-owned units.
    # File-profile and other non-constant identities are never resolution targets.
    class Registry
      TYPES = %i[model controller service poro lib concern job mailer component view_component
                 graphql_type graphql_mutation graphql_resolver graphql_query serializer manager
                 policy validator pundit_policy decorator action_cable_channel].freeze

      # @param units [Array<ExtractedUnit, Hash>] current complete typed unit set
      # @param sources [Hash{String => Hash}] path to collector result
      # @param root [String, Pathname] application root
      def initialize(units:, sources:, root:)
        @root = File.expand_path(root.to_s)
        @lookup = RuntimeLookup.new
        @sources = sources.to_h { |path, result| [absolute(path), result] }
        @all_types = units.group_by { |unit| field(unit, :identifier) }
        @entries = units.filter_map { |unit| entry(unit) }
        @owners = @entries.group_by { |record| [record[:path], record[:identifier]] }
        @targets = @entries.group_by { |record| record[:identifier] }
      end

      # @param reference [Hash] JSON-compatible collector reference record
      # @param file_path [String] source containing the reference
      # @return [Hash, nil] a dependency, or nil for an unresolved reference
      def resolve(reference, file_path:)
        result = explain(reference, file_path: file_path)
        return unless result['status'] == 'resolved'

        { type: result.fetch('type').to_sym, target: result.fetch('target'), via: :code_reference }
      end

      # @param reference [Hash] collected spelling, owner and lexical nesting
      # @param file_path [String] original source path
      # @return [Hash] JSON-compatible resolution or explicit unresolved reason
      def explain(reference, file_path:)
        return unresolved('unverified_owner') unless owner?(reference['owner'], file_path: file_path)

        return unresolved('unsupported_singleton_scope') if reference.fetch('singleton_depth', 0).positive?

        result = @lookup.call(reference['name'], nesting: reference.fetch('nesting', []))
        target = result[:target] || source_only_target(reference, result)
        return unresolved(result[:reason] || 'constant_missing') unless target

        target_result(target, owner: reference['owner'])
      end

      # @param identifier [String] source declaration identity
      # @param file_path [String] original source path
      # @return [Boolean] whether exactly one extracted type owns the declaration
      def owner?(identifier, file_path:)
        records = @owners[[absolute(file_path), identifier]]
        records && !records.empty? && !ambiguous?(identifier)
      end

      private

      def target_result(target, owner:)
        return unresolved('ambiguous_target') if ambiguous?(target)

        entries = @targets[target]
        return unresolved('target_not_indexed') unless entries&.any?
        return unresolved('self_reference') if target == owner

        { 'status' => 'resolved', 'target' => target, 'type' => entries.first[:type].to_s }
      end

      def entry(unit)
        type = field(unit, :type)&.to_sym
        return unless TYPES.include?(type)

        identifier = field(unit, :identifier)
        path = field(unit, :file_path)
        return unless eligible_identity?(identifier, path)

        path = absolute(path)
        source = @sources[path]
        return unless verified_declaration?(source, identifier, type)

        { identifier: identifier, type: type, path: path }
      end

      def eligible_identity?(identifier, path)
        path && identifier.is_a?(String) && RuntimeLookup::CONSTANT.match?(identifier)
      end

      def verified_declaration?(source, identifier, type)
        return false unless source && source['parse_error'].nil?

        source.fetch('declarations', []).any? { |decl| declaration?(decl, identifier, type) }
      end

      def declaration?(declaration, identifier, type)
        return false unless declaration['owner'] == identifier
        return false if declaration.fetch('singleton_depth', 0).positive?

        result = @lookup.call(declaration['name'], nesting: declaration.fetch('enclosing_nesting', []),
                                                  allow_private: true)
        return runtime_declaration?(declaration, identifier, result) if result[:status] == :resolved

        type == :lib && @lookup.call("::#{identifier}")[:status] == :missing &&
          static_declaration?(declaration, identifier)
      end

      def runtime_declaration?(declaration, identifier, result)
        kind = @lookup.class_object?(result[:value]) ? 'class' : 'module'
        result[:target] == identifier && declaration['kind'] == kind
      end

      def static_declaration?(declaration, identifier)
        name = declaration['name']
        return false unless name.is_a?(String) && RuntimeLookup::CONSTANT.match?(name)
        return name.delete_prefix('::') == identifier if name.start_with?('::')

        nesting = declaration.fetch('enclosing_nesting', [])
        return name == identifier if nesting.empty?

        !name.include?('::') && [nesting.first, name].join('::') == identifier
      end

      def source_only_target(reference, result)
        return unless result[:status] == :missing

        return unless reference['name'].to_s.start_with?('::') || result[:root_lookup]

        name = reference['name'].to_s.delete_prefix('::')
        candidates = @targets[name]
        name if candidates&.all? { |entry| entry[:type] == :lib }
      end

      def ambiguous?(identifier)
        @all_types.fetch(identifier, []).map { |unit| field(unit, :type).to_s }.uniq.size > 1
      end

      def field(unit, name)
        return unit.public_send(name) unless unit.is_a?(Hash)

        unit.key?(name) ? unit[name] : unit[name.to_s]
      end

      def absolute(path)
        File.expand_path(path.to_s, @root)
      end

      def unresolved(reason)
        { 'status' => 'unresolved', 'reason' => reason }
      end
    end
  end
end
