# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative '../source_references/runtime_lookup'
# ClassFamilies loads the Phlex and serializer extractors, and
# PathDispatcher's file rules name every extractor's directories. Both are
# loaded here rather than by the extractors that use this class, which
# {SharedUtilityMethods#inheritance_dependency} requires on first use, so
# no extractor file requires itself through this one.
require_relative 'class_families'
require_relative '../extractor'

module Woods
  module Extractors
    # The `:inheritance` edge from a class-based unit to its application-defined
    # parent, typed as the unit the parent's own extractor publishes.
    #
    # The parent is the runtime superclass, never a parsed name. It qualifies
    # when it is a named class whose definition is application source, and
    # the edge takes the unit type the owning extractor would give it:
    # {ClassFamilies} for the runtime-discovered families, then the
    # {PathDispatcher} file rule claiming its file for the file-discovered
    # ones. A parent no extractor publishes, an abstract Active Record base,
    # a ViewComponent preview or a framework class, yields no edge, so the
    # graph never carries an edge to a unit that does not exist. Controllers
    # and mailers keep their own, older copies of this rule.
    #
    # @example
    #   SuperclassDependency.new.call(Kit::CopyButton)
    #   # => { type: :component, target: 'Kit::Button', via: :inheritance }
    class SuperclassDependency
      include SharedUtilityMethods

      # {ClassFamilies} extractor key => the unit type that extractor publishes.
      FAMILY_TYPES = {
        models: :model,
        controllers: :controller,
        mailers: :mailer,
        action_cable_channels: :action_cable_channel,
        view_components: :view_component,
        components: :component,
        serializers: :serializer,
        jobs: :job
      }.freeze

      # {PathDispatcher} file-rule key => unit type, for the file-discovered
      # families that publish every class their directories declare. Checked
      # in order: `app/policies` is claimed by both policy extractors and
      # `app/decorators` by the serializer rule too.
      PATH_TYPES = {
        services: :service,
        policies: :policy,
        decorators: :decorator,
        validators: :validator,
        libs: :lib
      }.freeze

      # Claimed paths whose owner refuses a loaded class that is not its own
      # kind, leaving the file to the PORO owner fallback.
      FALLBACK_KEYS = %i[graphql managers].freeze

      SOURCE_LOCATION = Module.instance_method(:const_source_location)

      # @param app_root [String] Rails.root.to_s
      def initialize(app_root: Rails.root.to_s)
        @app_root = File.expand_path(app_root)
        @lookup = SourceReferences::RuntimeLookup.new
        # Parents repeat across a run (every job shares ApplicationJob, every
        # component its base), and typing one reflects over its methods when
        # it is not application source; answer each parent once per run.
        @types = {}.compare_by_identity
      end

      # @param unit_class [Class, String, Object] the unit's loaded class, or
      #   its identifier when the extractor read a declaration; anything else
      #   (a test double) resolves to nothing
      # @param file_path [String, nil] with an identifier, the file that
      #   declares it; a loaded class another file owns is never consulted
      # @return [Hash, nil] `{ type:, target:, via: :inheritance }` or nil
      def call(unit_class, file_path: nil)
        klass = unit_class.is_a?(Class) ? unit_class : owned_class(unit_class, file_path)
        return nil unless klass

        parent = klass.superclass
        return nil unless parent.is_a?(Class) && parent.name

        type = @types.fetch(parent) { @types[parent] = unit_type_for(parent) }
        { type: type, target: parent.name, via: :inheritance } if type
      end

      private

      # @return [Class, nil] the loaded class +identifier+ names when +file_path+ defines it
      def owned_class(identifier, file_path)
        return nil unless identifier.is_a?(String) && file_path

        result = @lookup.call("::#{identifier}", allow_private: true)
        klass = result[:value] if result[:status] == :resolved
        return nil unless @lookup.class_object?(klass)

        location = SOURCE_LOCATION.bind(Object).call(identifier, false)
        klass if location && File.expand_path(location.first) == File.expand_path(file_path)
      rescue StandardError
        nil
      end

      # @return [Symbol, nil] the unit type the parent's extractor publishes it as
      def unit_type_for(parent)
        path = definition_path(parent)
        return nil unless path

        family = ClassFamilies.owner_of(parent, @lookup, bases: family_bases)
        return family_type(family, parent) if family

        path_type(path.delete_prefix("#{@app_root}#{File::SEPARATOR}"), parent)
      end

      # @return [String, nil] the parent's application source file
      def definition_path(parent)
        path = resolve_source_location(parent, app_root: @app_root, fallback: nil)
        path if app_source?(path, @app_root) && File.file?(path)
      end

      def family_bases
        @family_bases ||= ClassFamilies.resolve_bases(@lookup)
      end

      # @return [Symbol, nil] the family's unit type, unless the family's
      #   extractor rejects this class
      def family_type(family, parent)
        case family
        when :models then :model unless abstract_model?(parent) || habtm_join_model?(parent)
        when :view_components then :view_component unless preview?(parent)
        when :graphql then graphql_type(parent)
        else FAMILY_TYPES[family]
        end
      end

      # @return [Symbol, nil] the type a file-discovered extractor publishes
      #   the parent as, by the rule claiming its file
      def path_type(relative, parent)
        keys = PathDispatcher.claiming_keys_for(relative)
        key = PATH_TYPES.keys.find { |candidate| keys.include?(candidate) }
        return PATH_TYPES[key] if key
        return :manager if keys.include?(:managers) && delegator?(parent)
        return :poro if keys.empty? && PathDispatcher.poro_path?(relative)

        :poro if (keys - FALLBACK_KEYS).empty? && PathDispatcher.fallback_candidate?(relative)
      end

      # Guarded as ModelExtractor#abstract_class? is: a class that raises is kept.
      def abstract_model?(parent)
        parent.respond_to?(:abstract_class?) && parent.abstract_class?
      rescue StandardError
        false
      end

      def habtm_join_model?(parent)
        parent.name.split('::').last.start_with?('HABTM_')
      end

      def preview?(parent)
        defined?(::ViewComponent::Preview) && parent <= ::ViewComponent::Preview
      end

      def delegator?(parent)
        defined?(::Delegator) && parent < ::Delegator
      end

      # Mirrors GraphQLExtractor#classify_runtime_type; a schema's query root
      # is never a parent, so its `:graphql_query` type is not reproduced.
      def graphql_type(parent)
        return :graphql_mutation if graphql_base?(parent, :Mutation)
        return :graphql_resolver if graphql_base?(parent, :Resolver)

        :graphql_type
      end

      def graphql_base?(parent, name)
        defined?(::GraphQL::Schema) && ::GraphQL::Schema.const_defined?(name, false) &&
          parent < ::GraphQL::Schema.const_get(name, false)
      end
    end
  end
end
