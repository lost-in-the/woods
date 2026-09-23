# frozen_string_literal: true

module Woods
  module SourceReferences
    # Optional parser-gem backend with the same ownership rules as Prism.
    class ParserAdapter
      DYNAMIC_BLOCK_METHODS = %i[class_eval module_eval instance_eval class_exec module_exec instance_exec].freeze

      def parse(source)
        require 'parser/current' unless defined?(::Parser::CurrentRuby)
        parser = ::Parser::CurrentRuby.default_parser
        diagnostics = []
        parser.diagnostics.consumer = ->(diagnostic) { diagnostics << diagnostic }
        parser.diagnostics.all_errors_are_fatal = true
        parser.diagnostics.ignore_warnings = true
        buffer = ::Parser::Source::Buffer.new('(source references)', source: source)
        [parser.parse(buffer), nil]
      rescue ::Parser::SyntaxError => e
        diagnostic = diagnostics.last
        [nil, { 'message' => e.message, 'line' => diagnostic&.location&.line || 1 }]
      end

      def kind(node)
        case node.type
        when :class, :module then :declaration
        when :const then :constant
        when :sclass then :singleton
        when :def, :defs then :method
        when :block, :numblock then dynamic_scope?(node) ? :dynamic_scope : :other
        else :other
        end
      end

      def constant_name(node)
        return unless node
        return '' if node.type == :cbase
        return unless node.type == :const

        parent, name = node.children
        prefix = parent ? constant_name(parent) : nil
        return if parent && !prefix

        [prefix, name.to_s].compact.join('::')
      end

      def children(node)
        nodes = case node.type
                when :casgn then [node.children[2]]
                when :masgn then [node.children[1]]
                when :defs then node.children.drop(2)
                else node.children
                end
        nodes.grep(::Parser::AST::Node)
      end

      def declaration_name(node)
        constant_name(node.children.first)
      end

      def declaration_kind(node)
        node.type.to_s
      end

      def superclass(node)
        node.children[1] if node.type == :class
      end

      def body(node)
        node.children.last
      end

      def self_receiver?(node)
        node.children.first.type == :self
      end

      def local_method?(node)
        node.type == :def || node.children.first.type == :self
      end

      def line(node)
        node.location.expression.line
      end

      def end_line(node)
        node.location.expression.last_line
      end

      private

      def dynamic_scope?(node)
        call = node.children.first
        return false unless %i[send csend].include?(call.type)

        receiver, method = call.children
        return true if DYNAMIC_BLOCK_METHODS.include?(method)

        foreign_method?(method, receiver) || anonymous_class?(method, receiver)
      end

      def foreign_method?(method, receiver)
        %i[define_method define_singleton_method].include?(method) && receiver && receiver.type != :self
      end

      def anonymous_class?(method, receiver)
        name = constant_name(receiver)&.delete_prefix('::')
        { new: %w[Class Module Struct], define: ['Data'] }.fetch(method, []).include?(name)
      end
    end
  end
end
