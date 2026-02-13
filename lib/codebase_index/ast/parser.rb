# frozen_string_literal: true

require_relative 'node'

module CodebaseIndex
  class Error < StandardError; end unless defined?(CodebaseIndex::Error)
  class ExtractionError < Error; end unless defined?(CodebaseIndex::ExtractionError)
  module Ast
    # Parser adapter that normalizes Prism and parser gem ASTs to a common
    # {Ast::Node} structure. Auto-detects parser availability at load time.
    #
    # @example Parsing Ruby source
    #   parser = Ast::Parser.new
    #   root = parser.parse("class Foo; def bar; end; end")
    #   root.find_all(:def).first.method_name #=> "bar"
    #
    class Parser
      # Parse Ruby source into a normalized AST.
      #
      # @param source [String] Ruby source code
      # @return [Ast::Node] Root node of the normalized tree
      # @raise [CodebaseIndex::ExtractionError] if parsing fails
      def parse(source)
        if prism_available?
          parse_with_prism(source)
        else
          parse_with_parser_gem(source)
        end
      rescue CodebaseIndex::ExtractionError
        raise
      rescue StandardError => e
        raise CodebaseIndex::ExtractionError, "Failed to parse source: #{e.message}"
      end

      # Check if Prism is available.
      #
      # @return [Boolean]
      def prism_available?
        if @prism_available.nil?
          begin
            require 'prism'
            @prism_available = defined?(Prism) ? true : false
          rescue LoadError
            @prism_available = false
          end
        end
        @prism_available
      end

      private

      # Parse using Prism (Ruby 3.3+ stdlib or backport gem).
      def parse_with_prism(source)
        require 'prism' unless defined?(Prism)

        result = Prism.parse(source)

        unless result.success?
          errors = result.errors.map(&:message).join(', ')
          raise CodebaseIndex::ExtractionError, "Parse error: #{errors}"
        end

        convert_prism_node(result.value, source)
      end

      # Parse using the parser gem (fallback for older Ruby).
      def parse_with_parser_gem(source)
        require 'parser/current' unless defined?(::Parser::CurrentRuby)

        buffer = ::Parser::Source::Buffer.new('(source)', source: source)
        ast = ::Parser::CurrentRuby.parse(buffer.source)

        raise CodebaseIndex::ExtractionError, 'Parse returned nil' unless ast

        convert_parser_node(ast, source)
      end

      # Convert a Prism node tree to Ast::Node.
      #
      # @param prism_node [Prism::Node] A Prism AST node
      # @param source [String] Original source for extracting text spans
      # @return [Ast::Node]
      def convert_prism_node(prism_node, source)
        case prism_node
        when Prism::ProgramNode
          children = convert_prism_children(prism_node.statements, source)
          Node.new(type: :program, children: children, line: line_for_prism(prism_node))
        when Prism::StatementsNode
          children = prism_node.body.map { |child| convert_prism_node(child, source) }
          Node.new(type: :begin, children: children, line: line_for_prism(prism_node))
        when Prism::ClassNode
          convert_prism_class(prism_node, source)
        when Prism::ModuleNode
          convert_prism_module(prism_node, source)
        when Prism::DefNode
          convert_prism_def(prism_node, source)
        when Prism::CallNode
          convert_prism_call(prism_node, source)
        when Prism::ConstantReadNode
          Node.new(
            type: :const,
            children: [],
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s
          )
        when Prism::ConstantPathNode
          convert_prism_constant_path(prism_node, source)
        when Prism::IfNode
          convert_prism_if(prism_node, source)
        when Prism::UnlessNode
          convert_prism_unless(prism_node, source)
        when Prism::CaseNode
          convert_prism_case(prism_node, source)
        when Prism::BeginNode
          children = []
          if prism_node.statements
            children += prism_node.statements.body.map { |c| convert_prism_node(c, source) }
          end
          if prism_node.rescue_clause
            children << convert_prism_node(prism_node.rescue_clause, source)
          end
          if prism_node.ensure_clause
            children << convert_prism_node(prism_node.ensure_clause, source)
          end
          Node.new(type: :begin, children: children, line: line_for_prism(prism_node))
        when Prism::RescueNode
          children = prism_node.statements ? prism_node.statements.body.map { |c| convert_prism_node(c, source) } : []
          Node.new(type: :rescue, children: children, line: line_for_prism(prism_node))
        when Prism::EnsureNode
          children = prism_node.statements ? prism_node.statements.body.map { |c| convert_prism_node(c, source) } : []
          Node.new(type: :ensure, children: children, line: line_for_prism(prism_node))
        when Prism::SymbolNode
          prism_node.value.to_s
        when Prism::StringNode
          prism_node.unescaped
        when Prism::IntegerNode
          prism_node.value
        when Prism::FloatNode
          prism_node.value
        when Prism::NilNode
          nil
        when Prism::TrueNode
          Node.new(type: :true, children: [], line: line_for_prism(prism_node))
        when Prism::FalseNode
          Node.new(type: :false, children: [], line: line_for_prism(prism_node))
        when Prism::SelfNode
          Node.new(type: :self, children: [], line: line_for_prism(prism_node), source: 'self')
        when Prism::LocalVariableReadNode
          Node.new(
            type: :lvar,
            children: [],
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s,
            source: prism_node.name.to_s
          )
        when Prism::LocalVariableWriteNode
          value = prism_node.value ? convert_prism_node(prism_node.value, source) : nil
          Node.new(
            type: :lvasgn,
            children: [value].compact,
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s,
            source: prism_node.name.to_s
          )
        when Prism::InstanceVariableReadNode
          Node.new(
            type: :ivar,
            children: [],
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s,
            source: prism_node.name.to_s
          )
        when Prism::InstanceVariableWriteNode
          value = prism_node.value ? convert_prism_node(prism_node.value, source) : nil
          Node.new(
            type: :ivasgn,
            children: [value].compact,
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s,
            source: prism_node.name.to_s
          )
        when Prism::BlockNode
          children = prism_node.body ? [convert_prism_node(prism_node.body, source)] : []
          Node.new(type: :block_body, children: children, line: line_for_prism(prism_node))
        when Prism::LambdaNode
          children = prism_node.body ? [convert_prism_node(prism_node.body, source)] : []
          Node.new(type: :lambda, children: children, line: line_for_prism(prism_node))
        when Prism::ReturnNode
          children = prism_node.arguments ? prism_node.arguments.arguments.map { |a| convert_prism_node(a, source) } : []
          Node.new(type: :return, children: children, line: line_for_prism(prism_node))
        when Prism::YieldNode
          Node.new(type: :yield, children: [], line: line_for_prism(prism_node))
        when Prism::ArrayNode
          children = prism_node.elements.map { |e| convert_prism_node(e, source) }
          Node.new(type: :array, children: children, line: line_for_prism(prism_node))
        when Prism::HashNode
          Node.new(type: :hash, children: [], line: line_for_prism(prism_node))
        when Prism::ParenthesesNode
          convert_prism_node(prism_node.body, source)
        when Prism::InterpolatedStringNode
          Node.new(type: :dstr, children: [], line: line_for_prism(prism_node))
        when Prism::SingletonClassNode
          children = prism_node.body ? [convert_prism_node(prism_node.body, source)] : []
          Node.new(type: :sclass, children: children, line: line_for_prism(prism_node))
        when Prism::ConstantWriteNode
          value = prism_node.value ? convert_prism_node(prism_node.value, source) : nil
          Node.new(
            type: :casgn,
            children: [value].compact,
            line: line_for_prism(prism_node),
            method_name: prism_node.name.to_s
          )
        else
          # Generic fallback: convert children we can find
          children = extract_prism_generic_children(prism_node, source)
          Node.new(
            type: prism_node.class.name.split('::').last.sub(/Node$/, '').gsub(/([a-z])([A-Z])/, '\1_\2').downcase.to_sym,
            children: children,
            line: line_for_prism(prism_node)
          )
        end
      end

      def convert_prism_class(prism_node, source)
        name_node = convert_prism_node(prism_node.constant_path, source)
        superclass = prism_node.superclass ? convert_prism_node(prism_node.superclass, source) : nil
        body_children = if prism_node.body
                          prism_node.body.is_a?(Prism::StatementsNode) ? prism_node.body.body.map { |c| convert_prism_node(c, source) } : [convert_prism_node(prism_node.body, source)]
                        else
                          []
                        end

        children = [name_node, superclass] + body_children

        Node.new(
          type: :class,
          children: children,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          method_name: extract_const_name(prism_node.constant_path)
        )
      end

      def convert_prism_module(prism_node, source)
        name_node = convert_prism_node(prism_node.constant_path, source)
        body_children = if prism_node.body
                          prism_node.body.is_a?(Prism::StatementsNode) ? prism_node.body.body.map { |c| convert_prism_node(c, source) } : [convert_prism_node(prism_node.body, source)]
                        else
                          []
                        end

        children = [name_node] + body_children

        Node.new(
          type: :module,
          children: children,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          method_name: extract_const_name(prism_node.constant_path)
        )
      end

      def convert_prism_def(prism_node, source)
        body_children = if prism_node.body
                          if prism_node.body.is_a?(Prism::StatementsNode)
                            prism_node.body.body.map { |c| convert_prism_node(c, source) }
                          else
                            [convert_prism_node(prism_node.body, source)]
                          end
                        else
                          []
                        end

        is_class_method = prism_node.respond_to?(:receiver) && prism_node.receiver
        receiver_text = if is_class_method
                          src = prism_node.receiver
                          src.is_a?(Prism::SelfNode) ? 'self' : extract_prism_source_text(src, source)
                        end

        Node.new(
          type: is_class_method ? :defs : :def,
          children: body_children,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          method_name: prism_node.name.to_s,
          receiver: receiver_text,
          source: extract_prism_source_span(prism_node, source)
        )
      end

      def convert_prism_call(prism_node, source)
        receiver_text = if prism_node.receiver
                          extract_prism_receiver_text(prism_node.receiver, source)
                        end

        args = if prism_node.arguments
                 prism_node.arguments.arguments.map { |a| extract_prism_source_text(a, source) }
               else
                 []
               end

        # Convert receiver node so tree walking finds nested calls/constants
        receiver_node = prism_node.receiver ? convert_prism_node(prism_node.receiver, source) : nil
        children = [receiver_node].compact

        # If there's a block, create a :block node wrapping this send
        if prism_node.block && prism_node.block.is_a?(Prism::BlockNode)
          send_node = Node.new(
            type: :send,
            children: children,
            line: line_for_prism(prism_node),
            receiver: receiver_text,
            method_name: prism_node.name.to_s,
            arguments: args
          )

          block_body = if prism_node.block.body
                         convert_prism_node(prism_node.block.body, source)
                       end

          return Node.new(
            type: :block,
            children: [send_node, block_body].compact,
            line: line_for_prism(prism_node),
            end_line: end_line_for_prism(prism_node.block)
          )
        end

        Node.new(
          type: :send,
          children: children,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          receiver: receiver_text,
          method_name: prism_node.name.to_s,
          arguments: args
        )
      end

      def convert_prism_constant_path(prism_node, source)
        parent_text = if prism_node.parent
                        extract_const_path_text(prism_node.parent)
                      end

        Node.new(
          type: :const,
          children: [],
          line: line_for_prism(prism_node),
          receiver: parent_text,
          method_name: prism_node.name.to_s
        )
      end

      def convert_prism_if(prism_node, source)
        condition = convert_prism_node(prism_node.predicate, source)
        condition_source = extract_prism_source_text(prism_node.predicate, source)
        if condition.is_a?(Node) && condition.source.nil?
          condition = Node.new(**condition.to_h.merge(source: condition_source))
        end

        then_body = prism_node.statements ? convert_prism_node(prism_node.statements, source) : nil
        else_body = prism_node.subsequent ? convert_prism_node(prism_node.subsequent, source) : nil

        Node.new(
          type: :if,
          children: [condition, then_body, else_body].compact,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          source: condition_source
        )
      end

      def convert_prism_unless(prism_node, source)
        condition = convert_prism_node(prism_node.predicate, source)
        condition_source = extract_prism_source_text(prism_node.predicate, source)

        then_body = prism_node.statements ? convert_prism_node(prism_node.statements, source) : nil
        else_body = prism_node.else_clause ? convert_prism_node(prism_node.else_clause, source) : nil

        Node.new(
          type: :if,
          children: [condition, then_body, else_body].compact,
          line: line_for_prism(prism_node),
          end_line: end_line_for_prism(prism_node),
          source: condition_source
        )
      end

      def convert_prism_case(prism_node, source)
        children = []
        children << convert_prism_node(prism_node.predicate, source) if prism_node.predicate
        prism_node.conditions.each { |c| children << convert_prism_node(c, source) }
        if prism_node.else_clause
          children << convert_prism_node(prism_node.else_clause, source)
        end
        Node.new(type: :case, children: children, line: line_for_prism(prism_node))
      end

      def convert_prism_children(statements_node, source)
        return [] unless statements_node

        if statements_node.is_a?(Prism::StatementsNode)
          statements_node.body.map { |c| convert_prism_node(c, source) }
        else
          [convert_prism_node(statements_node, source)]
        end
      end

      def extract_prism_generic_children(prism_node, source)
        children = []
        prism_node.child_nodes.compact.each do |child|
          converted = convert_prism_node(child, source)
          children << converted if converted
        end
        children
      end

      def line_for_prism(node)
        node.location.start_line
      end

      def end_line_for_prism(node)
        node.location.end_line
      end

      def extract_prism_source_span(node, source)
        lines = source.lines
        start_idx = node.location.start_line - 1
        end_idx = node.location.end_line - 1
        return nil if start_idx < 0 || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end

      def extract_prism_source_text(node, source)
        source.byteslice(node.location.start_offset, node.location.length) || ''
      rescue StandardError
        ''
      end

      def extract_prism_receiver_text(receiver_node, source)
        case receiver_node
        when Prism::SelfNode
          'self'
        when Prism::ConstantReadNode
          receiver_node.name.to_s
        when Prism::ConstantPathNode
          extract_const_path_text(receiver_node)
        when Prism::CallNode
          text = extract_prism_receiver_text(receiver_node.receiver, source) if receiver_node.receiver
          [text, receiver_node.name.to_s].compact.join('.')
        when Prism::LocalVariableReadNode
          receiver_node.name.to_s
        when Prism::InstanceVariableReadNode
          receiver_node.name.to_s
        else
          extract_prism_source_text(receiver_node, source)
        end
      end

      def extract_const_path_text(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? extract_const_path_text(node.parent) : nil
          [parent, node.name.to_s].compact.join('::')
        else
          nil
        end
      end

      def extract_const_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          extract_const_path_text(node)
        else
          nil
        end
      end

      # ── Parser gem fallback ──────────────────────────────────────────────

      def convert_parser_node(parser_node, source)
        return nil unless parser_node
        return nil unless parser_node.is_a?(::Parser::AST::Node)

        case parser_node.type
        when :begin
          children = parser_node.children.map { |c| convert_parser_node(c, source) }.compact
          Node.new(type: :begin, children: children, line: parser_node.loc&.line || 1)
        when :class
          name_node = convert_parser_node(parser_node.children[0], source)
          superclass = parser_node.children[1] ? convert_parser_node(parser_node.children[1], source) : nil
          body = parser_node.children[2] ? convert_parser_node(parser_node.children[2], source) : nil
          body_children = body&.type == :begin ? body.children : [body].compact
          children = [name_node, superclass] + body_children
          Node.new(
            type: :class,
            children: children,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression.last_line,
            method_name: extract_parser_const_name(parser_node.children[0])
          )
        when :module
          name_node = convert_parser_node(parser_node.children[0], source)
          body = parser_node.children[1] ? convert_parser_node(parser_node.children[1], source) : nil
          body_children = body&.type == :begin ? body.children : [body].compact
          children = [name_node] + body_children
          Node.new(
            type: :module,
            children: children,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression.last_line,
            method_name: extract_parser_const_name(parser_node.children[0])
          )
        when :def
          body = parser_node.children[2] ? convert_parser_node(parser_node.children[2], source) : nil
          body_children = body&.type == :begin ? body.children : [body].compact
          Node.new(
            type: :def,
            children: body_children,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression.last_line,
            method_name: parser_node.children[0].to_s,
            source: extract_parser_source_span(parser_node, source)
          )
        when :defs
          body = parser_node.children[3] ? convert_parser_node(parser_node.children[3], source) : nil
          body_children = body&.type == :begin ? body.children : [body].compact
          receiver = parser_node.children[0].type == :self ? 'self' : parser_node.children[0].to_s
          Node.new(
            type: :defs,
            children: body_children,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression.last_line,
            method_name: parser_node.children[1].to_s,
            receiver: receiver,
            source: extract_parser_source_span(parser_node, source)
          )
        when :send
          receiver_text = parser_node.children[0] ? extract_parser_receiver_text(parser_node.children[0], source) : nil
          method_name = parser_node.children[1].to_s
          args = parser_node.children[2..].compact.map { |a| extract_parser_source_text(a, source) }
          Node.new(
            type: :send,
            children: [],
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression&.last_line,
            receiver: receiver_text,
            method_name: method_name,
            arguments: args
          )
        when :block
          send_child = convert_parser_node(parser_node.children[0], source)
          body = parser_node.children[2] ? convert_parser_node(parser_node.children[2], source) : nil
          Node.new(
            type: :block,
            children: [send_child, body].compact,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression.last_line
          )
        when :if
          condition = convert_parser_node(parser_node.children[0], source)
          condition_source = extract_parser_source_text(parser_node.children[0], source)
          if condition.is_a?(Node) && condition.source.nil?
            condition = Node.new(**condition.to_h.merge(source: condition_source))
          end
          then_body = parser_node.children[1] ? convert_parser_node(parser_node.children[1], source) : nil
          else_body = parser_node.children[2] ? convert_parser_node(parser_node.children[2], source) : nil
          Node.new(
            type: :if,
            children: [condition, then_body, else_body].compact,
            line: parser_node.loc.line,
            end_line: parser_node.loc.expression&.last_line,
            source: condition_source
          )
        when :const
          parent = parser_node.children[0] ? extract_parser_const_name(parser_node.children[0]) : nil
          Node.new(
            type: :const,
            children: [],
            line: parser_node.loc.line,
            receiver: parent,
            method_name: parser_node.children[1].to_s
          )
        when :sym
          parser_node.children[0].to_s
        when :str
          parser_node.children[0]
        when :int
          parser_node.children[0]
        when :float
          parser_node.children[0]
        when :nil
          nil
        when :true
          Node.new(type: :true, children: [], line: parser_node.loc.line)
        when :false
          Node.new(type: :false, children: [], line: parser_node.loc.line)
        when :self
          Node.new(type: :self, children: [], line: parser_node.loc.line, source: 'self')
        else
          children = parser_node.children.filter_map do |child|
            child.is_a?(::Parser::AST::Node) ? convert_parser_node(child, source) : nil
          end
          Node.new(
            type: parser_node.type,
            children: children,
            line: parser_node.loc&.line || 1
          )
        end
      end

      def extract_parser_source_span(node, source)
        lines = source.lines
        start_idx = node.loc.line - 1
        end_idx = node.loc.expression.last_line - 1
        return nil if start_idx < 0 || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end

      def extract_parser_source_text(node, source)
        return node.to_s unless node.is_a?(::Parser::AST::Node) && node.loc&.expression

        loc = node.loc.expression
        source[loc.begin_pos...loc.end_pos] || ''
      rescue StandardError
        ''
      end

      def extract_parser_receiver_text(node, source)
        case node.type
        when :self
          'self'
        when :const
          extract_parser_const_name(node)
        when :send
          recv = node.children[0] ? extract_parser_receiver_text(node.children[0], source) : nil
          [recv, node.children[1].to_s].compact.join('.')
        when :lvar, :ivar
          node.children[0].to_s
        else
          extract_parser_source_text(node, source)
        end
      end

      def extract_parser_const_name(node)
        return nil unless node.is_a?(::Parser::AST::Node)

        case node.type
        when :const
          parent = node.children[0] ? extract_parser_const_name(node.children[0]) : nil
          [parent, node.children[1].to_s].compact.join('::')
        else
          nil
        end
      end
    end
  end
end
