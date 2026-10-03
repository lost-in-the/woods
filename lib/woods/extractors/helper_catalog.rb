# frozen_string_literal: true

require 'prism'
require 'set'
require_relative '../source_file'

module Woods
  module Extractors
    # The application's helper methods: which name is defined by which helper
    # module, and which controller declares a name with `helper_method`.
    #
    # Source is the primary evidence. Every module under {HELPER_DIRECTORIES}
    # is read with Prism for the public instance methods its body defines.
    # The runtime then adds three things source alone cannot show:
    #
    # * app-defined modules in a controller's or mailer's `_helpers` ancestry
    #   that live outside {HELPER_DIRECTORIES} (`helper Formatting`);
    # * methods a loaded module defines dynamically in its own file
    #   (`define_method`, `alias_method`);
    # * names a controller or mailer exposes with `helper_method`, attributed
    #   to the class that declares them.
    #
    # The runtime also orders an ambiguous name: {#resolve} asks the calling
    # context's `_helpers` module which definition Rails would run.
    #
    # One instance spans one extractor instance, which spans one run.
    #
    # @example
    #   catalog = HelperCatalog.new
    #   catalog.names.include?('pretty_date')            # => true
    #   catalog.resolve('pretty_date', WidgetsController)
    #   # => [{ type: :poro, target: 'DateHelper', via: :helper_call }]
    class HelperCatalog
      # Directories whose modules Rails mixes into views by convention.
      HELPER_DIRECTORIES = %w[app/helpers].freeze

      # Extractors whose output carries helper edges, re-run wholesale when
      # a helper module's file changes.
      CONSUMERS = %i[view_templates components view_components controllers mailers].freeze

      # The consumers with no owning controller in the dependency graph
      # (layouts, shared partials, components), re-run when the default
      # context's ancestry changes. Owned views follow their controller
      # through the blast radius.
      VIEW_CONSUMERS = %i[view_templates components view_components].freeze

      # Runtime base classes whose descendants carry a `_helpers` module.
      CONTEXT_BASES = %w[ActionController::Base ActionMailer::Base].freeze

      # The controller an ownerless template or a component resolves through.
      DEFAULT_CONTEXT = 'ApplicationController'

      CONSTANT_PATH = /\A(?:::)?[A-Z]\w*+(?:::[A-Z]\w*+)*+\z/
      VISIBILITY_CALLS = %i[public private protected module_function].freeze
      UNINDEXED_SEGMENTS = %w[vendor node_modules].freeze

      # One helper module: where it is declared and what it defines.
      #
      # @!attribute name
      #   @return [String] qualified module name
      # @!attribute files
      #   @return [Array<String>] root-relative files declaring it
      # @!attribute definitions
      #   @return [Hash{String => Array}] method name => `[file, line]`
      Entry = Struct.new(:name, :files, :definitions)

      class << self
        # Extractor keys to re-run wholesale for a set of changed paths.
        #
        # @param relative_paths [Enumerable<String>] root-relative paths
        # @return [Array<Symbol>]
        def consumer_keys_for(relative_paths)
          return [] unless relative_paths.any? { |path| path.end_with?('.rb') }

          new.consumer_keys_for(relative_paths)
        end
      end

      # @return [String] absolute application root
      attr_reader :root

      # @param root [Pathname, String] application root
      # @param contexts [Array<Class>, nil] controller and mailer classes;
      #   discovered from the runtime when nil
      # @param default_context [Class, nil] context for an ownerless caller;
      #   {DEFAULT_CONTEXT} at runtime when omitted
      def initialize(root: Rails.root, contexts: nil, default_context: :runtime)
        @root = File.expand_path(root.to_s)
        @given_contexts = contexts
        @default_context = default_context
      end

      # @return [Hash{String => Entry}] catalog modules by name, name-sorted
      def modules
        @modules ||= build_modules
      end

      # @return [Set<String>] every helper method name in the application
      def names
        @names ||= modules.each_value.flat_map { |entry| entry.definitions.keys }.to_set
                          .merge(declarations.each_value.flat_map(&:to_a))
      end

      # @param name [String] method name
      # @return [Array<String>] names of the modules defining it, sorted
      def candidates(name)
        modules.each_value.select { |entry| entry.definitions.key?(name) }.map(&:name)
      end

      # @param name [String] method name
      # @return [Array<Hash>] `{ module:, file:, line: }` per defining module
      def definitions(name)
        candidates(name).map do |module_name|
          file, line = modules.fetch(module_name).definitions.fetch(name)
          { module: module_name, file: file, line: line }
        end
      end

      # Names a controller or mailer class declares with `helper_method`
      # (or defines in a `helper do` block), excluding inherited ones.
      #
      # @param klass [Class]
      # @return [Array<String>] sorted
      def declared_helper_methods(klass)
        declarations.fetch(klass, []).to_a.sort
      end

      # Edges for a name called in a view context. With a context whose
      # `_helpers` module knows the name, the edge is to the definition Rails
      # would run. Otherwise every module defining the name is a target, and
      # more than one target is marked ambiguous.
      #
      # @param name [String] method name
      # @param context [Class, nil] owning controller or mailer; the default
      #   context when nil
      # @return [Array<Hash>] `{ type:, target:, via: }` (plus `ambiguous:`)
      def resolve(name, context)
        return [] unless names.include?(name)

        owner = helper_owner(name, context || default_context)
        declarer = helpers_owners[owner]
        return [declaration_edge(declarer)] if declarer && declarations.fetch(declarer, []).include?(name)

        targets = candidates(name)
        targets = [owner.name] if owner && targets.include?(owner.name)
        targets.map { |target| module_edge(target, ambiguous: targets.size > 1) }
      end

      # Method names a class can call without a receiver because it includes
      # the catalog module that defines them.
      #
      # @param klass [Class]
      # @return [Set<String>]
      def included_names(klass)
        modules.each_value.with_object(Set.new) do |entry, found|
          mod = runtime_constant(entry.name)
          found.merge(entry.definitions.keys) if mod.is_a?(Module) && klass.include?(mod)
        end
      end

      # Edge for a receiverless call inside a class that includes helper
      # modules. A name the class (or a nearer ancestor) defines itself
      # resolves there, so it yields no edge.
      #
      # @param name [String]
      # @param klass [Class]
      # @return [Array<Hash>]
      def resolve_included(name, klass)
        owner = klass.instance_method(name.to_sym).owner
        modules.key?(owner.name) && modules[owner.name].definitions.key?(name) ? [module_edge(owner.name)] : []
      rescue NameError
        []
      end

      # @param module_name [String] a catalog module
      # @return [Symbol] the unit type its file is indexed as
      def target_type(module_name)
        file = modules.fetch(module_name).files.first
        return :concern if file.include?('/concerns/')

        file.start_with?('lib/') ? :lib : :poro
      end

      # @return [Class, nil] the context an ownerless caller resolves through
      def default_context
        return @default_context unless @default_context == :runtime

        @default_context = runtime_constant(DEFAULT_CONTEXT).then { |klass| klass if klass.respond_to?(:_helpers) }
      end

      # @see .consumer_keys_for
      def consumer_keys_for(relative_paths)
        ruby = relative_paths.select { |path| path.end_with?('.rb') }
        return CONSUMERS if ruby.any? { |path| helper_source?(path) }
        return VIEW_CONSUMERS if ruby.any? { |path| default_context_files.include?(path) }

        []
      end

      private

      # ── Source ──────────────────────────────────────────────────────────

      def build_modules
        entries = {}
        helper_files.each { |file| read_modules(file, entries) }
        runtime_helper_modules.each { |mod| read_runtime_module(mod, entries) }
        entries.each_value { |entry| add_dynamic_methods(entry) }
        entries.sort.to_h
      end

      def helper_files
        HELPER_DIRECTORIES.flat_map { |dir| Dir[File.join(@root, dir, '**', '*.rb')] }.sort
                          .map { |path| relative(path) }
      end

      def helper_source?(relative_path)
        HELPER_DIRECTORIES.any? { |dir| relative_path.start_with?("#{dir}/") } ||
          runtime_helper_modules.any? { |mod| module_files(mod).include?(relative_path) }
      end

      # @param file [String] root-relative path
      # @param entries [Hash{String => Entry}]
      # @param only [String, nil] restrict to one module name
      def read_modules(file, entries, only: nil)
        result = Prism.parse(SourceFile.read(File.join(@root, file)))
        return if result.failure?

        walk(result.value, nil, file, entries, only)
      rescue SystemCallError, ArgumentError
        nil
      end

      def walk(node, nesting, file, entries, only)
        case node
        when Prism::ModuleNode, Prism::ClassNode
          name = qualified_name(node.constant_path, nesting)
          return unless name

          record_module(node, name, file, entries) if node.is_a?(Prism::ModuleNode) && (only.nil? || only == name)
          statements(node.body).each { |child| walk(child, name, file, entries, only) }
        when Prism::ProgramNode, Prism::StatementsNode
          node.compact_child_nodes.each { |child| walk(child, nesting, file, entries, only) }
        end
      end

      def qualified_name(constant_path, nesting)
        path = constant_path.slice
        return nil unless path.match?(CONSTANT_PATH)
        return path.delete_prefix('::') if path.start_with?('::')

        [nesting, path].compact.join('::')
      end

      def statements(body)
        body.is_a?(Prism::StatementsNode) ? body.body : []
      end

      # Public instance methods in body order, tracking `private`-style
      # switches the way Ruby applies them to the definitions that follow.
      def record_module(node, name, file, entries)
        entry = entries[name] ||= Entry.new(name, [], {})
        entry.files << file unless entry.files.include?(file)
        visibility = :public
        statements(node.body).each do |statement|
          case statement
          when Prism::DefNode
            record_method(entry, statement, file) if visibility == :public && statement.receiver.nil?
          when Prism::CallNode
            visibility = apply_visibility(statement, visibility, entry, file)
          end
        end
      end

      def record_method(entry, def_node, file)
        entry.definitions[def_node.name.to_s] ||= [file, def_node.location.start_line]
      end

      def apply_visibility(call, visibility, entry, file)
        return visibility unless call.receiver.nil? && VISIBILITY_CALLS.include?(call.name)

        arguments = call.arguments&.arguments || []
        return call.name if arguments.empty?

        arguments.each do |argument|
          case argument
          when Prism::DefNode then record_method(entry, argument, file) if call.name == :public
          when Prism::SymbolNode, Prism::StringNode
            entry.definitions.delete(argument.unescaped) unless call.name == :public
          end
        end
        visibility
      end

      # ── Runtime ─────────────────────────────────────────────────────────

      def contexts
        @contexts ||= (@given_contexts || discovered_contexts).sort_by { |klass| [klass.ancestors.size, klass.name] }
      end

      def discovered_contexts
        CONTEXT_BASES.filter_map { |name| runtime_constant(name) }
                     .flat_map { |base| base.respond_to?(:descendants) ? base.descendants : [] }
                     .uniq
                     .select { |klass| klass.name && klass.respond_to?(:_helpers) && app_class?(klass) }
      end

      def app_class?(klass)
        app_file?(constant_file(klass.name))
      end

      # Each class's `_helpers` module, keyed by identity. A subclass that
      # shares its parent's module is not an owner: parents come first.
      def helpers_owners
        @helpers_owners ||= contexts.each_with_object({}.compare_by_identity) do |klass, owners|
          owners[klass._helpers] ||= klass
        end
      end

      # @return [Hash{Class => Set<String>}] names each owner's `_helpers`
      #   module defines itself: `helper_method` delegators and `helper do`
      #   block methods
      def declarations
        @declarations ||= helpers_owners.each_with_object({}.compare_by_identity) do |(helpers, klass), found|
          declared = helpers.instance_methods(false).map(&:to_s)
          found[klass] = declared.to_set unless declared.empty?
        end
      end

      # Named, app-defined modules in any context's helpers ancestry.
      def runtime_helper_modules
        @runtime_helper_modules ||= contexts.flat_map { |klass| klass._helpers.ancestors }.uniq
                                            .reject { |mod| mod.is_a?(Class) || helpers_owners.key?(mod) || !mod.name }
                                            .select { |mod| app_file?(constant_file(mod.name)) }
                                            .sort_by(&:name)
      end

      # A runtime module joins the catalog from the file that declares it,
      # unless a helper directory already supplied it.
      def read_runtime_module(mod, entries)
        return if entries.key?(mod.name)

        read_modules(constant_file(mod.name), entries, only: mod.name)
      end

      # Methods the loaded module has that no `def` in its body shows,
      # provided they were created in one of its own files.
      def add_dynamic_methods(entry)
        mod = runtime_constant(entry.name)
        return unless mod.is_a?(Module) && !mod.is_a?(Class)

        mod.public_instance_methods(false).sort.each do |method_name|
          file, line = mod.instance_method(method_name).source_location
          file &&= relative(file)
          entry.definitions[method_name.to_s] ||= [file, line] if entry.files.include?(file)
        end
      end

      # Files a runtime module's definitions come from.
      def module_files(mod)
        locations = mod.instance_methods(false).filter_map { |name| mod.instance_method(name).source_location&.first }
        ([constant_file(mod.name)] + locations.map { |file| relative(file) }).compact.uniq
      end

      # The module Rails would run `name` from in a context, if its
      # `_helpers` module knows the name.
      def helper_owner(name, context)
        return nil unless context.respond_to?(:_helpers)

        context._helpers.instance_method(name.to_sym).owner
      rescue NameError
        nil
      end

      def default_context_files
        @default_context_files ||= Array(default_context&.ancestors).filter_map { |mod| mod.name && constant_file(mod.name) }
                                                                    .select { |file| app_file?(file) }.to_set
      end

      # ── Edges ───────────────────────────────────────────────────────────

      def module_edge(target, ambiguous: false)
        edge = { type: target_type(target), target: target, via: :helper_call }
        ambiguous ? edge.merge(ambiguous: true) : edge
      end

      def declaration_edge(klass)
        mailer = runtime_constant('ActionMailer::Base')
        type = mailer.is_a?(Class) && klass <= mailer ? :mailer : :controller
        { type: type, target: klass.name, via: :helper_method }
      end

      # ── Paths and constants ─────────────────────────────────────────────

      def relative(path)
        File.expand_path(path.to_s, @root).delete_prefix("#{@root}/")
      end

      # @return [String, nil] root-relative file declaring the constant
      def constant_file(name)
        file = Object.const_source_location(name)&.first
        file && !file.empty? ? relative(file) : nil
      rescue NameError
        nil
      end

      def app_file?(relative_path)
        return false unless relative_path&.end_with?('.rb')
        return false unless relative_path.start_with?('app/', 'lib/')

        (relative_path.split('/') & UNINDEXED_SEGMENTS).empty?
      end

      # Look a constant up one segment at a time without inheritance or
      # autoloading surprises: a missing constant is nil.
      def runtime_constant(name)
        name.split('::').reduce(Object) do |scope, part|
          return nil unless scope.is_a?(Module) && scope.const_defined?(part, false)

          scope.const_get(part, false)
        end
      rescue StandardError
        nil
      end
    end
  end
end
