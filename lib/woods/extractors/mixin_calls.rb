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
      # @return [Array<Array(Symbol, String)>] the call and the constant as
      #   written (a leading `::` kept), in source order
      def call(source, kinds = KINDS, own_only: true)
        visitor = visit(source, kinds, own_only)
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
        visitor = visit(source, kinds, false)
        return [] unless visitor

        visitor.found.filter_map do |kind, name, nesting|
          resolved = visitor.resolve(name, nesting)
          [kind, name] unless resolved&.start_with?("#{owner}::")
        end
      end

      # @return [Visitor, nil] the visitor after its walk, nil for no source
      def visit(source, kinds, own_only)
        return nil unless source.is_a?(String) && !source.empty?

        visitor = Visitor.new(kinds, own_only)
        Woods::ParseCache.parse(source).value.accept(visitor)
        visitor
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
        CONSTANTS = [Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

        # @return [Array<Array(Symbol, String, Array<String>)>] call, constant
        #   as written, enclosing qualified names (innermost last)
        attr_reader :found

        def initialize(kinds, own_only)
          super()
          @kinds = kinds
          @found = []
          @own_only = own_only
          @method_depth = 0
          @nesting = []
          @declared = Set.new
        end

        # The declared module or class a constant names, by lexical lookup
        # from +nesting+, or nil when it names nothing this source declares.
        #
        # @param name [String] constant as written
        # @param nesting [Array<String>]
        # @return [String, nil]
        def resolve(name, nesting)
          candidates =
            if name.start_with?('self::')
              nesting.last(1).map { |scope| "#{scope}::#{name.delete_prefix('self::')}" }
            elsif name.start_with?('::')
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
              next unless CONSTANTS.any? { |type| argument.is_a?(type) }

              @found << [node.name, argument.slice.gsub(/\s+/, ''), @nesting.dup]
            end
          end
          super
        end

        # @param node [Prism::DefNode]
        def visit_def_node(node)
          @method_depth += 1
          super
        ensure
          @method_depth -= 1
        end

        private

        def within(node)
          path = node.constant_path.slice.gsub(/\s+/, '')
          qualified = if path.start_with?('::') || @nesting.empty? then path.delete_prefix('::')
                      else "#{@nesting.last}::#{path}"
                      end
          @declared << qualified
          @nesting.push(qualified)
          yield
        ensure
          @nesting.pop if qualified
        end

        def own?(node)
          @method_depth.zero? && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        end
      end
    end
  end
end
