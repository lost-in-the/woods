# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../ast/node'
require_relative '../ast/call_site_extractor'
require_relative 'response_code_mapper'

module CodebaseIndex
  module FlowAnalysis
    # Extracts operations from a method body AST in source line order.
    #
    # Uses Ast::CallSiteExtractor for raw call sites, then classifies each
    # into domain-meaningful operation types: calls, transactions, async
    # enqueues, responses, conditionals, cycles, and dynamic dispatch.
    #
    # @example Extracting operations from a method body
    #   parser = Ast::Parser.new
    #   root = parser.parse(source)
    #   method_node = root.find_all(:def).find { |n| n.method_name == "create" }
    #   ops = OperationExtractor.new.extract(method_node)
    #   ops.first[:type] #=> :call
    #
    class OperationExtractor
      TRANSACTION_METHODS = %w[transaction with_lock].freeze
      ASYNC_METHODS = %w[perform_async perform_later perform_in perform_at].freeze
      RESPONSE_METHODS = %w[redirect_to head respond_with].freeze
      DYNAMIC_DISPATCH_METHODS = %w[send public_send].freeze

      # Extract operations from a method definition node in source line order.
      #
      # @param method_node [Ast::Node] A :def or :defs node
      # @return [Array<Hash>] Operations ordered by source line
      def extract(method_node)
        return [] unless method_node.is_a?(Ast::Node)

        operations = []
        walk(method_node, operations)
        operations
      end

      private

      # Recursively walk the AST and extract operations.
      def walk(node, operations)
        return unless node.is_a?(Ast::Node)

        case node.type
        when :block
          handle_block(node, operations)
        when :send
          handle_send(node, operations)
        when :if
          handle_conditional(node, operations)
        when :case
          handle_case(node, operations)
        else
          walk_children(node, operations)
        end
      end

      # Walk all children of a node.
      def walk_children(node, operations)
        return unless node.children

        node.children.each { |child| walk(child, operations) }
      end

      # Handle :block nodes - check for transaction/with_lock wrappers.
      def handle_block(node, operations)
        send_child = node.children&.first
        if send_child.is_a?(Ast::Node) && send_child.type == :send && transaction_call?(send_child)
          nested = []
          # Walk block body (children after the send node)
          node.children&.drop(1)&.each { |child| walk(child, nested) }

          operations << {
            type: :transaction,
            receiver: send_child.receiver,
            line: send_child.line,
            nested: nested
          }
        else
          # Non-transaction block: emit the send as a normal call, walk body
          handle_send(send_child, operations) if send_child.is_a?(Ast::Node) && send_child.type == :send
          node.children&.drop(1)&.each { |child| walk(child, operations) }
        end
      end

      # Handle :send nodes - classify into operation types.
      def handle_send(node, operations)
        return unless node.is_a?(Ast::Node) && node.type == :send

        if async_call?(node)
          operations << {
            type: :async,
            target: node.receiver,
            method: node.method_name,
            args_hint: node.arguments || [],
            line: node.line
          }
        elsif dynamic_dispatch?(node)
          operations << {
            type: :dynamic_dispatch,
            target: node.receiver,
            method: node.method_name,
            args_hint: node.arguments || [],
            line: node.line
          }
        elsif response_call?(node)
          operations << {
            type: :response,
            status_code: ResponseCodeMapper.resolve_method(node.method_name, arguments: node.arguments || []),
            render_method: node.method_name,
            line: node.line
          }
        elsif significant_call?(node)
          operations << {
            type: :call,
            target: node.receiver,
            method: node.method_name,
            line: node.line
          }
        end

        # Do NOT recurse into send node children — the walker handles
        # children at the statement level. Recursing here would double-count
        # chained calls and pick up receiver lvars as spurious method calls.
      end

      # Handle :if nodes - extract conditional with then/else branches.
      def handle_conditional(node, operations)
        then_ops = []
        else_ops = []

        # children[0] = condition, children[1] = then, children[2] = else
        children = node.children || []
        walk(children[1], then_ops) if children[1].is_a?(Ast::Node)
        walk(children[2], else_ops) if children[2].is_a?(Ast::Node)

        return if then_ops.empty? && else_ops.empty?

        condition_text = if children[0].is_a?(Ast::Node)
                           children[0].to_source
                         elsif children[0].is_a?(String)
                           children[0]
                         end

        operations << {
          type: :conditional,
          kind: 'if',
          condition: condition_text || node.source,
          line: node.line,
          then_ops: then_ops,
          else_ops: else_ops
        }
      end

      # Handle :case nodes as a conditional variant.
      def handle_case(node, operations)
        # Treat case as a conditional - extract ops from all branches
        branch_ops = []
        walk_children(node, branch_ops)

        return if branch_ops.empty?

        operations << {
          type: :conditional,
          kind: 'case',
          condition: node.source,
          line: node.line,
          then_ops: branch_ops,
          else_ops: []
        }
      end

      # Detect transaction/with_lock calls.
      def transaction_call?(node)
        TRANSACTION_METHODS.include?(node.method_name)
      end

      # Detect async enqueue calls.
      def async_call?(node)
        ASYNC_METHODS.include?(node.method_name)
      end

      # Detect response calls (render, redirect_to, head, render_*).
      def response_call?(node)
        return true if RESPONSE_METHODS.include?(node.method_name)
        return true if node.method_name&.start_with?('render')

        false
      end

      # Detect dynamic dispatch (send, public_send).
      def dynamic_dispatch?(node)
        DYNAMIC_DISPATCH_METHODS.include?(node.method_name)
      end

      # Determine if a call is significant enough to include.
      def significant_call?(node)
        return false if node.method_name.nil?
        return false if Ast::INSIGNIFICANT_METHODS.include?(node.method_name)
        return false if transaction_call?(node) # Handled by block wrapper

        true
      end
    end
  end
end
