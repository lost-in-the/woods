# frozen_string_literal: true

require 'pathname'
require_relative 'runtime_lookup'
require_relative 'value_class'
require_relative '../source_contributors'

module Woods
  module SourceReferences
    # Maps verified source declarations to extracted constant-owned units.
    # File-profile and other non-constant identities are never resolution targets.
    class Registry # rubocop:disable Metrics/ClassLength -- keep runtime, source and autoload ownership checks together
      TYPES = %i[model controller service poro lib concern job mailer component view_component
                 graphql_type graphql_mutation graphql_resolver graphql_query serializer manager
                 policy validator pundit_policy decorator action_cable_channel].freeze

      # @param units [Array<ExtractedUnit, Hash>] current complete typed unit set
      # @param sources [Hash{String => Hash}] path to collector result
      # @param root [String, Pathname] application root
      def initialize(units:, sources:, root:)
        @root = File.expand_path(root.to_s)
        @lookup = RuntimeLookup.new(memoize: true)
        @sources = sources.to_h { |path, result| [absolute(path), result] }
        @all_types = units.group_by { |unit| field(unit, :identifier) }
        @entries = units.flat_map { |unit| SourceContributors.paths(unit).filter_map { |path| entry(unit, path) } }
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

        result, spelling = lookup(reference)
        target = result[:target] || autoload_target(result) || source_only_target(reference, result)
        return unresolved(result[:reason] || 'constant_missing') unless target

        target_result(target, owner: reference['owner'], spelling: spelling)
      end

      # Unresolved reasons whose source evidence still names a candidate: the
      # runtime lookup did not contradict a lexical reading of the spelling.
      # A runtime target outside the index, an unverifiable owner or a
      # self-reference never yields one.
      NO_CANDIDATE_REASONS = %w[unverified_owner target_not_indexed self_reference invalid_constant].freeze

      # Typed candidates for an unresolved reference, from its literal spelling
      # read against the lexical nesting (innermost first, then top level), or
      # every type of a runtime target several unit types share. Static
      # evidence only: Ruby's lookup through ancestors is not modelled.
      #
      # @param reference [Hash] collected spelling, owner and lexical nesting
      # @param result [Hash] the unresolved {#explain} result
      # @return [Array<Array(String, String)>] sorted [target, type] pairs
      def candidates(reference, result)
        return [] if result['status'] == 'resolved' || NO_CANDIDATE_REASONS.include?(result['reason'])

        names = result['reason'] == 'ambiguous_target' ? [result['target']] : lexical_names(reference)
        names.uniq.flat_map { |name| typed_targets(name).map { |type| [name, type] } }
             .reject { |name, _| name == reference['owner'] }.uniq.sort
      end

      # @param identifier [String]
      # @return [Array<String>] the constant-owned unit types declaring it, sorted
      def typed_targets(identifier)
        Array(@targets[identifier]).map { |entry| entry[:type].to_s }.uniq.sort
      end

      # @param identifier [String] source declaration identity
      # @param file_path [String] original source path
      # @return [Boolean] whether exactly one extracted type owns the declaration
      def owner?(identifier, file_path:)
        records = @owners[[absolute(file_path), identifier]]
        records && !records.empty? && !ambiguous?(identifier)
      end

      private

      # A value read through a class (`Kit::Button::VARIANTS`,
      # `::CoreModel::UNSHIPPED`) is a read of the class (LOS-126): the path
      # is cut back one segment at a time while it names a value, and the
      # first class or module it reaches is the target. A nested class or
      # module is its own constant and credits nothing but itself, and an
      # absent path still resolves to nothing. The spelling is the credited
      # prefix as written, so a span can cover it.
      #
      # @param name [String] the constant path as written
      # @param nesting [Array<String>] lexical scopes, innermost first
      # @param original [Hash] the lookup of the whole path
      # @return [Array(Hash, String, nil)] the lookup to use and the credited spelling
      def value_owner(name, nesting, original)
        path = name
        while (cut = path.rindex('::')) && cut.positive?
          path = path[0...cut]
          result = @lookup.call(path, nesting: nesting)
          return [result, path] if result[:status] == :resolved
          break unless result[:reason] == 'non_module_constant'
        end
        [original, nil]
      end

      # @return [Array(Hash, String, nil)] the lookup of the reference, or of
      #   the class a value is read through, with that class path as written
      def lookup(reference)
        nesting = reference.fetch('nesting', [])
        result = @lookup.call(reference['name'], nesting: nesting)
        return [result, nil] unless result[:reason] == 'non_module_constant'

        value_owner(reference['name'], nesting, result)
      end

      def target_result(target, owner:, spelling: nil)
        return unresolved('ambiguous_target').merge('target' => target) if ambiguous?(target)

        entries = @targets[target]
        return unresolved('target_not_indexed') unless entries&.any?
        return unresolved('self_reference') if target == owner

        resolved = { 'status' => 'resolved', 'target' => target, 'type' => entries.first[:type].to_s }
        spelling ? resolved.merge('spelling' => spelling) : resolved
      end

      def lexical_names(reference)
        name = reference['name'].to_s
        return [] unless RuntimeLookup::CONSTANT.match?(name)
        return [name.delete_prefix('::')] if name.start_with?('::')

        reference.fetch('nesting', []).map { |scope| "#{scope}::#{name}" } + [name]
      end

      def entry(unit, path)
        type = field(unit, :type)&.to_sym
        return unless TYPES.include?(type)

        identifier = field(unit, :identifier)
        return unless eligible_identity?(identifier, path)

        path = absolute(path)
        source = @sources[path]
        return unless verified_declaration?(source, identifier, type, path)

        { identifier: identifier, type: type, path: path }
      end

      def eligible_identity?(identifier, path)
        path && identifier.is_a?(String) && RuntimeLookup::CONSTANT.match?(identifier)
      end

      def verified_declaration?(source, identifier, type, path)
        return false unless source && source['parse_error'].nil?

        source.fetch('declarations', []).any? { |decl| declaration?(decl, identifier, type, path) }
      end

      def declaration?(declaration, identifier, type, path)
        return false unless declaration['owner'] == identifier
        return false if declaration.fetch('singleton_depth', 0).positive?

        return ValueClass.new.call(declaration, file_path: path) == identifier if declaration['constructor']

        result = @lookup.call(declaration['name'], nesting: declaration.fetch('enclosing_nesting', []),
                                                   allow_private: true)
        return runtime_declaration?(declaration, identifier, result) if result[:status] == :resolved

        source_declaration?(declaration, identifier, type, path)
      end

      def source_declaration?(declaration, identifier, type, path)
        return false unless type == :lib && static_declaration?(declaration, identifier)

        root_result = @lookup.call("::#{identifier}", allow_private: true)
        root_result[:status] == :missing || autoload_declaration?(root_result, identifier, path)
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

      def autoload_declaration?(result, identifier, path)
        registered = result[:autoload_path]
        result[:pending_target] == identifier && registered.is_a?(String) &&
          Pathname.new(registered).absolute? && absolute(registered) == path
      end

      def autoload_target(result)
        name = result[:pending_target]
        candidates = @targets[name]
        return unless candidates&.any?

        name if candidates.all? { |entry| entry[:type] == :lib && autoload_declaration?(result, name, entry[:path]) }
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
