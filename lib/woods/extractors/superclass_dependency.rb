# frozen_string_literal: true

require_relative 'shared_utility_methods'
require_relative 'declared_parent'
require_relative '../source_file'
require_relative '../source_references/runtime_lookup'
require_relative '../parse_cache'
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
    # A library is autoloaded, not eager-loaded, so during extraction it and
    # its library parent are usually pending autoloads (#965). When the
    # runtime registers the unit's autoload at its own file, the parent is
    # read from that file's declaration and resolved lexically, the way Ruby
    # would, against the constants the runtime defines or registers. Nothing
    # is loaded: loading would change what later lookups see, and a full run
    # and an incremental run would then disagree.
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
      # A class may override `self.name`; the edge names its constant.
      CONSTANT_NAME = Module.instance_method(:name)

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
        return pending_edge(unit_class, file_path) unless klass

        loaded_edge(klass.superclass)
      end

      private

      # @return [Hash, nil] the edge to a loaded parent class
      def loaded_edge(parent)
        return nil unless @lookup.class_object?(parent)

        name = CONSTANT_NAME.bind_call(parent)
        return nil unless name

        type = @types.fetch(parent) { @types[parent] = unit_type_for(parent) }
        { type: type, target: name, via: :inheritance } if type
      end

      # The edge of a unit the runtime registers as a pending autoload at
      # +file_path+, from its declared parent.
      #
      # @return [Hash, nil]
      def pending_edge(identifier, file_path)
        return nil unless identifier.is_a?(String) && file_path
        return nil unless pending_at?(@lookup.call("::#{identifier}", allow_private: true), identifier, file_path)

        declared = DeclaredParent.declaration(SourceFile.read(file_path), identifier)
        declared && declared_parent_edge(declared)
      rescue StandardError
        nil
      end

      # Ruby binds a relative parent's first segment in the innermost
      # enclosing scope that defines it, then at the top level, and walks
      # the rest from there. A scope the runtime does not know the segment
      # in is skipped, as Ruby skips it.
      def declared_parent_edge(declared)
        parent = declared[:parent]
        target = if parent.start_with?('::')
                   parent.delete_prefix('::')
                 else
                   first = parent.split('::').first
                   scope = declared[:nesting].find { |candidate| known?("#{candidate}::#{first}") }
                   [scope, parent].compact.join('::')
                 end
        result = @lookup.call("::#{target}", allow_private: true)
        candidate_edge(result, target) unless result[:status] == :missing
      end

      # @return [Boolean] whether the runtime defines or registers +name+;
      #   under a pending namespace, whether its conventional file or
      #   directory exists, which is what the autoloader would define it from
      def known?(name)
        result = @lookup.call("::#{name}", allow_private: true)
        return false if result[:status] == :missing
        return true unless result[:pending_remainder]

        path = pending_path(result, name)
        !path.nil? && (File.file?(path) || File.directory?(path.delete_suffix('.rb')))
      end

      # @return [Hash, nil] the edge to the candidate the runtime holds: a
      #   loaded class, or a library still pending at its autoload path
      def candidate_edge(result, candidate)
        return loaded_edge(result[:value]) if result[:status] == :resolved

        path = pending_path(result, candidate)
        return nil unless path && app_source?(path, @app_root) && File.file?(path)

        type = pending_type(path.delete_prefix("#{@app_root}#{File::SEPARATOR}"))
        { type: type, target: candidate, via: :inheritance } if type && declares_class?(path, candidate)
      end

      # @return [Boolean] whether the runtime's autoload evidence places
      #   +identifier+ in +file_path+
      def pending_at?(result, identifier, file_path)
        path = pending_path(result, identifier)
        !path.nil? && path == File.expand_path(file_path)
      end

      # The file the runtime would load for a pending +identifier+: its own
      # autoload path, or under a pending namespace the conventional path the
      # namespace's registration puts it at.
      #
      # @return [String, nil] an absolute path
      def pending_path(result, identifier)
        return nil unless result[:reason] == 'autoload_pending' && result[:pending_target] == identifier

        registered = result[:autoload_path]
        return nil unless registered.is_a?(String) && Pathname.new(registered).absolute?

        remainder = result[:pending_remainder]
        return File.expand_path(registered) unless remainder

        segments = remainder.map { |part| ActiveSupport::Inflector.underscore(part) }
        File.expand_path("#{File.join(registered.delete_suffix('.rb'), *segments)}.rb")
      end

      # @return [Boolean] whether the file declares +identifier+ as a class,
      #   so a module the autoloader would define there is never a parent
      def declares_class?(path, identifier)
        parsed = Woods::ParseCache.parse(SourceFile.read(path))
        parsed.success? && class_declared?(parsed.value, identifier, '')
      end

      def class_declared?(node, identifier, namespace)
        return false unless node

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          name = node.constant_path.slice
          qualified = name.start_with?('::') ? name.delete_prefix('::') : [namespace, name].reject(&:empty?).join('::')
          return node.is_a?(Prism::ClassNode) if qualified == identifier

          return class_declared?(node.body, identifier, qualified)
        end

        node.compact_child_nodes.any? { |child| class_declared?(child, identifier, namespace) }
      end

      # The type a file-discovered extractor publishes a pending parent as.
      # Without a loaded class the delegator and family checks cannot run,
      # so only the plain file rules answer.
      def pending_type(relative)
        keys = PathDispatcher.claiming_keys_for(relative)
        key = PATH_TYPES.keys.find { |candidate| keys.include?(candidate) }
        PATH_TYPES[key] if key
      end

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
        CONSTANT_NAME.bind_call(parent).split('::').last.start_with?('HABTM_')
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
