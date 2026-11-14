# frozen_string_literal: true

require 'prism'
require 'set'
require_relative '../parse_cache'

module Woods
  module Extractors
    # The mixins a Ruby source declares: each `include`, `extend` or
    # `prepend` call and each constant written as its argument, read from the
    # Prism tree. Only a real call declares a mixin; a comment, string,
    # heredoc or method name that contains the word does not, and neither
    # does an argument that is not a constant (`extend self`). By default a
    # call counts only without a receiver or on `self`, outside any method
    # body: a call on another receiver acts on that receiver, so
    # `base.extend ClassMethods` inside `self.included` is no mixin of this
    # source's module. `own_only: false` reads every call, for the modules a
    # source's mixin calls reference wherever they apply them, and
    # {outside_owner} reads every call except the owner's own modules.
    module MixinCalls
      KINDS = %i[include extend prepend].freeze
      HELPER_NAME = /\A\w+Helper\z/

      module_function

      # @param source [String] Ruby source
      # @param kinds [Array<Symbol>] which of {KINDS} to read
      # @param own_only [Boolean] only the calls that mix into the module or
      #   class being read (no receiver or `self`, outside a method body)
      # @param owner [String, nil] qualified name of the module being read,
      #   for a source whose enclosing namespace modules were blanked out: a
      #   top-level declaration whose name ends +owner+ is read as +owner+
      # @return [Array<Array(Symbol, String)>] the call and the constant as
      #   written (a leading `::` kept), in source order
      def call(source, kinds = KINDS, own_only: true, owner: nil)
        visitor = visit(source, kinds, own_only, owner)
        visitor ? visitor.found.map { |kind, name, _nesting| [kind, name] } : []
      end

      # Every call, wherever it applies its constants, except a constant
      # that resolves to a module or class +owner+ declares in its own body
      # (`ClassMethods`, `self::ClassMethods`, `Owner::ClassMethods`). Such a
      # module is part of the owner, not something it brings in.
      #
      # @param source [String] Ruby source
      # @param owner [String] qualified name of the module being read
      # @param kinds [Array<Symbol>] which of {KINDS} to read
      # @return [Array<Array(Symbol, String)>] as {call}
      def outside_owner(source, owner, kinds = KINDS)
        visitor = visit(source, kinds, false, owner)
        return [] unless visitor

        visitor.found.filter_map do |kind, name, nesting|
          resolved = visitor.resolve(name, nesting)
          [kind, name] unless resolved&.start_with?("#{owner}::")
        end
      end

      # The visitor after its walk, nil for no source. A source that already
      # declares +owner+ by its full name is read as written; only one whose
      # namespace modules were blanked out is rooted at +owner+.
      #
      # @return [Visitor, nil]
      def visit(source, kinds, own_only, owner = nil)
        return nil unless source.is_a?(String) && !source.empty?

        tree = Woods::ParseCache.parse(source).value
        visitor = Visitor.new(kinds, own_only)
        tree.accept(visitor)
        return visitor if owner.nil? || visitor.declares?(owner)

        Visitor.new(kinds, own_only, owner).tap { |rooted| tree.accept(rooted) }
      end

      # The `*Helper` modules a source includes by bare name, as the helper
      # scans of component and mailer extractors have always read them.
      #
      # @param source [String] Ruby source
      # @return [Array<String>] distinct names in source order
      def helper_includes(source)
        call(source, %i[include]).map(&:last).grep(HELPER_NAME).uniq
      end

      # Collects the constant arguments of the chosen calls, each with the
      # lexical module nesting it was written in, and every module and class
      # the source declares.
      class Visitor < Prism::Visitor
        # @return [Array<Array(Symbol, String, Array<String>)>] call, constant
        #   as written, enclosing qualified names (innermost last)
        attr_reader :found

        def initialize(kinds, own_only, owner = nil)
          super()
          @owner = owner
          @kinds = kinds
          @found = []
          @own_only = own_only
          @method_depth = 0
          @nesting = []
          @declared = Set.new
          @self_is = :other
        end

        # @param name [String] a qualified module or class name
        # @return [Boolean] whether this source declares it
        def declares?(name)
          @declared.include?(name)
        end

        # The declared module or class a constant names, by lexical lookup
        # from +nesting+, or nil when it names nothing this source declares.
        #
        # @param name [String] constant as written
        # @param nesting [Array<String>]
        # @return [String, nil]
        def resolve(name, nesting)
          candidates =
            if name.start_with?('::')
              [name.delete_prefix('::')]
            else
              nesting.reverse.map { |scope| "#{scope}::#{name}" } << name
            end
          candidates.find { |candidate| @declared.include?(candidate) }
        end

        # @param node [Prism::ModuleNode]
        def visit_module_node(node)
          within(node) { super }
        end

        # @param node [Prism::ClassNode]
        def visit_class_node(node)
          within(node) { super }
        end

        # @param node [Prism::CallNode]
        def visit_call_node(node)
          if @kinds.include?(node.name) && (!@own_only || own?(node))
            node.arguments&.arguments.to_a.each do |argument|
              name = self_resolved(constant_name(argument))
              @found << [node.name, name, @nesting.dup] if name
            end
          end
          super
        end

        # @param node [Prism::DefNode]
        def visit_def_node(node)
          @method_depth += 1
          self_is(self_in_method(node.receiver)) { super }
        ensure
          @method_depth -= 1
        end

        # `class << self` in a module body: self is its singleton class.
        #
        # @param node [Prism::SingletonClassNode]
        def visit_singleton_class_node(node)
          inside = node.expression.is_a?(Prism::SelfNode) && @self_is == :module ? :singleton_class : :other
          self_is(inside) { super }
        end

        # A block may run with any self (`class_eval`, `included do`).
        #
        # @param node [Prism::BlockNode]
        def visit_block_node(node)
          self_is(:other) { super }
        end

        # @param node [Prism::LambdaNode]
        def visit_lambda_node(node)
          self_is(:other) { super }
        end

        private

        def within(node, &block)
          qualified = rooted(declared_name(constant_name(node.constant_path) || node.constant_path.slice))
          @declared << qualified
          @nesting.push(qualified)
          self_is(:module, &block)
        ensure
          @nesting.pop if qualified
        end

        # A top-level declaration of the owner's last name segments is the
        # owner, written inside namespace modules the source no longer holds.
        def rooted(qualified)
          return qualified unless @owner && @nesting.empty? && @owner.end_with?("::#{qualified}")

          @owner
        end

        def self_is(state)
          outer = @self_is
          @self_is = state
          yield
        ensure
          @self_is = outer
        end

        # What self is inside a method defined here: the module for
        # `def self.x` in its body or `def x` in its `class << self`.
        def self_in_method(receiver)
          case receiver
          when nil then @self_is == :singleton_class ? :module : :other
          when Prism::SelfNode then @self_is == :module ? :module : :other
          else :other
          end
        end

        # `self::X` names the enclosing module's X only where self is that
        # module; elsewhere it names nothing this source can tell.
        def self_resolved(name)
          return name unless name&.start_with?('self::')
          return nil unless @self_is == :module && @nesting.any?

          "::#{@nesting.last}::#{name.delete_prefix('self::')}"
        end

        # The qualified name of a module or class declared at +path+ here. A
        # qualified path's first constant is looked up lexically among the
        # modules already declared (`module Outer::Trackable` inside `Outer`
        # is `Outer::Trackable`); an unknown one is taken as nested.
        def declared_name(path)
          return path.delete_prefix('::') if path.start_with?('::') || @nesting.empty?

          first, rest = path.split('::', 2)
          scope = rest && (@nesting.reverse.map { |outer| "#{outer}::#{first}" } << first).find do |candidate|
            @declared.include?(candidate)
          end
          scope ? "#{scope}::#{rest}" : "#{@nesting.last}::#{path}"
        end

        # The constant a node names, built from its path (`A::B`, `::A::B`,
        # `self::A`), or nil for anything else, including a path with a
        # dynamic part (`base::A`).
        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            prefix = case node.parent
                     when nil then ''
                     when Prism::SelfNode then 'self'
                     else constant_name(node.parent)
                     end
            "#{prefix}::#{node.name}" if prefix
          end
        end

        def own?(node)
          @method_depth.zero? && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end
      end
    end
  end
end
