# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../ast/node'
require_relative '../ast/call_site_extractor'
require_relative 'response_code_mapper'

module Woods
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

      # Keys of an operation that hold the operations nested inside it.
      NESTED_KEYS = %i[nested then_ops else_ops].freeze

      # Node types of a `super` call: explicit arguments, bare (Prism), and bare (parser gem).
      SUPER_TYPES = %i[super forwarding_super zsuper].freeze

      # Node types whose children do not run where they are written: a
      # lambda body (Prism), the operand of `defined?` (Prism, parser gem).
      UNEVALUATED_TYPES = %i[lambda defined defined?].freeze

      # Receiverless calls whose block becomes a callable instead of running.
      DEFERRING_CALLS = %w[lambda proc].freeze

      # Whether a :block node builds a lambda or proc, so that its body runs
      # only when something calls it: `-> {}` (a :block over :lambda in the
      # parser gem), `lambda {}`, `proc {}` and `Proc.new {}`.
      #
      # @param node [Ast::Node]
      # @return [Boolean]
      def self.deferred_block?(node)
        call = node.type == :block && node.children&.first
        return false unless call.is_a?(Ast::Node)
        return true if call.type == :lambda
        return false unless call.type == :send

        return DEFERRING_CALLS.include?(call.method_name) if call.receiver.nil?

        call.method_name == 'new' && call.receiver.delete_prefix('::') == 'Proc'
      end

      # Rewrite each operation's +line+, +statement_line+ and +file+, nested
      # operations included, from the lines its AST was parsed at.
      #
      # @param operations [Array<Hash>]
      # @yieldparam line [Integer, nil] the line in the parsed text
      # @yieldreturn [Array(Integer, String)] the line and file to report;
      #   nil for either when the parsed line has no place in a file
      # @return [Array<Hash>] +operations+, rewritten in place
      def self.relocate(operations, &locate)
        operations.each do |operation|
          operation[:statement_line] = locate.call(operation[:statement_line]).first if operation[:statement_line]
          operation[:line], operation[:file] = locate.call(operation[:line])
          NESTED_KEYS.each { |key| relocate(operation[key], &locate) if operation[key] }
        end
      end

      # @param super_calls [Boolean] mark each `super` call with a
      #   `{ type: :super_call }` operation where Ruby makes it: after its
      #   arguments, before its block, inside the branch or block that holds
      #   it. Without it a `super` call is no operation.
      # @param inside_definition [Boolean] @api private: true for the walker
      #   of a definition's own statements, where a nested `def` only installs
      #   a method
      def initialize(super_calls: false, inside_definition: false)
        @super_calls = super_calls
        @inside_definition = inside_definition
      end

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
        return if UNEVALUATED_TYPES.include?(node.type)
        return handle_super(node, nil, operations) if super_call?(node)

        case node.type
        when :block
          handle_block(node, operations)
        when :send
          handle_send(node, operations)
        when :if
          handle_conditional(node, operations)
        when :case
          handle_case(node, operations)
        when :def, :defs
          @inside_definition ? walk_nested_definition(node, operations) : walk_definition(node, operations)
        else
          walk_children(node, operations)
        end
      end

      # Default parameter values run before the body, though the parser
      # places them after it. The receiver of `def (expr).name` ran when the
      # method was defined, not when it is called.
      def walk_definition(node, operations)
        children = Array(node.children).reject { |child| child.is_a?(Ast::Node) && child.type == :definition_receiver }
        defaults, body = children.partition { |child| child.is_a?(Ast::Node) && child.type == :parameter_defaults }
        walker = (@definition_walker ||= self.class.new(super_calls: @super_calls, inside_definition: true))
        (defaults + body).each { |child| walker.send(:walk, child, operations) }
      end

      # A method defined while this one runs: its defaults and body run only
      # when it is called, but the receiver of `def (expr).name` runs now.
      def walk_nested_definition(node, operations)
        Array(node.children).each do |child|
          walk_children(child, operations) if child.is_a?(Ast::Node) && child.type == :definition_receiver
        end
      end

      # Walk all children of a node.
      def walk_children(node, operations)
        return unless node.children

        node.children.each { |child| walk(child, operations) }
      end

      # Handle :block nodes - check for transaction/with_lock wrappers.
      def handle_block(node, operations)
        # A lambda or proc literal builds a callable; neither it nor its body
        # is an operation here.
        return if self.class.deferred_block?(node)

        send_child = node.children&.first
        if send_child.is_a?(Ast::Node) && send_child.type == :send && transaction_call?(send_child)
          nested = []
          # Walk block body (children after the send node)
          node.children&.drop(1)&.each { |child| walk(child, nested) }

          operations << {
            type: :transaction,
            receiver: send_child.receiver,
            **call_lines(send_child),
            nested: nested
          }
        elsif super_call?(send_child)
          # The parser gem wraps `super do ... end` the way it wraps a call.
          handle_super(send_child, node.children.drop(1), operations)
        else
          # Non-transaction block: emit the send as a normal call, walk body
          handle_send(send_child, operations) if send_child.is_a?(Ast::Node) && send_child.type == :send
          node.children&.drop(1)&.each { |child| walk(child, operations) }
        end
      end

      def super_call?(node)
        @super_calls && node.is_a?(Ast::Node) && SUPER_TYPES.include?(node.type)
      end

      # A `super` call evaluates its arguments, then calls the next
      # definition, which runs any block it was given.
      #
      # @param node [Ast::Node] the `super` node
      # @param block [Array<Ast::Node>, nil] the block body, when the parser
      #   holds it outside +node+; otherwise read from +node+'s children
      # @param nested [Boolean] whether the call is part of an expression
      #   (another call's receiver or argument), where only `super` calls
      #   are marked, as only enqueues are collected there
      def handle_super(node, block, operations, nested: false)
        children = Array(node.children).grep(Ast::Node)
        block ||= children.select { |child| child.type == :block_body }
        visit = nested ? method(:collect_nested_super) : method(:walk)
        (children - block).each { |child| visit.call(child, operations) }
        operations << { type: :super_call, line: node.line }
        block.each { |child| visit.call(child, operations) }
      end

      # Mark each `super` call in the expression +node+, a call's receiver or
      # argument, where Ruby makes it: before that call, and inside the
      # conditional expression (`ok? ? super : {}`) that holds it.
      def collect_nested_super(node, operations)
        return unless node.is_a?(Ast::Node)
        return handle_super(node, nil, operations, nested: true) if super_call?(node)
        return if deferred_expression?(node)

        case node.type
        when :if then collect_conditional_super(node, operations, 'if')
        when :case then collect_conditional_super(node, operations, 'case')
        else Array(node.children).each { |child| collect_nested_super(child, operations) }
        end
      end

      # An expression whose code runs only when something calls it.
      def deferred_expression?(node)
        UNEVALUATED_TYPES.include?(node.type) || %i[def defs].include?(node.type) || self.class.deferred_block?(node)
      end

      # The `super` calls of an `if` or `case` expression: its predicate's
      # first, then each branch's inside a conditional, as
      # {#handle_conditional} and {#handle_case} lay out statements.
      def collect_conditional_super(node, operations, kind)
        children = node.children || []
        collect_nested_super(children[0], operations)
        branches = kind == 'if' ? [[children[1]], [children[2]]] : [children.drop(1), []]
        then_ops, else_ops = branches.map do |branch|
          branch.each_with_object([]) { |child, ops| collect_nested_super(child, ops) }
        end
        return if then_ops.empty? && else_ops.empty?

        operations << { type: :conditional, kind: kind, condition: condition_source(children[0]) || node.source,
                        line: node.line, then_ops: then_ops, else_ops: else_ops }
      end

      # Handle :send nodes - classify into operation types.
      def handle_send(node, operations)
        return unless node.is_a?(Ast::Node) && node.type == :send
        return walk_negated(node, operations) if negation?(node)

        # Ruby evaluates a call's receiver and arguments before the call.
        (node.children || []).each { |child| collect_nested_super(child, operations) } if @super_calls

        if async_call?(node)
          operations << {
            type: :async,
            target: node.receiver,
            method: node.method_name,
            args_hint: node.arguments || [],
            **call_lines(node)
          }
        elsif dynamic_dispatch?(node)
          operations << {
            type: :dynamic_dispatch,
            target: node.receiver,
            method: node.method_name,
            args_hint: node.arguments || [],
            **call_lines(node)
          }
        elsif response_call?(node)
          operations << {
            type: :response,
            status_code: ResponseCodeMapper.resolve_method(node.method_name, arguments: node.arguments || []),
            render_method: node.method_name,
            **call_lines(node)
          }
        elsif significant_call?(node)
          operations << {
            type: :call,
            target: node.receiver,
            method: node.method_name,
            **call_lines(node)
          }
        end

        # Do NOT recurse into send node children in general — the walker
        # handles children at the statement level, and recursing here would
        # double-count chained calls and pick up receiver lvars as spurious
        # method calls. The one exception is an enqueue nested in the call's
        # receiver chain or arguments: `Audit.record(job: NotifyJob.perform_later)`
        # and `NotifyJob.perform_later.job_id` still enqueue the job (F5).
        (node.children || []).each { |child| collect_nested_async(child, operations) }
      end

      # A call's +line+ is where it names its method, so a call laid out over
      # several lines points at the call rather than at its receiver. The line
      # the call starts on follows as +statement_line+ when it differs.
      #
      # @param node [Ast::Node] a :send node
      # @return [Hash]
      def call_lines(node)
        line = node.message_line || node.line
        line == node.line ? { line: line } : { line: line, statement_line: node.line }
      end

      # `!x` and `not x` are a `!` call on +x+. The negation is noise; the
      # call it negates is the operation (`return if !buffered_data_present?`).
      def negation?(node)
        node.method_name == '!' && node.receiver && node.children&.first.is_a?(Ast::Node)
      end

      def walk_negated(node, operations)
        walk(node.children.first, operations)
      end

      # Emit `:async` for every enqueue call in the expression +node+, through
      # any literal, operator, interpolation or nested call. Only async calls
      # are emitted, so no other nested call is counted. A lambda or proc
      # body, a `defined?` operand and a nested definition do not run here.
      def collect_nested_async(node, operations)
        return unless node.is_a?(Ast::Node)
        return if UNEVALUATED_TYPES.include?(node.type) || %i[def defs].include?(node.type)
        return if self.class.deferred_block?(node)

        if node.type == :send && async_call?(node)
          operations << { type: :async, target: node.receiver, method: node.method_name,
                          args_hint: node.arguments || [], **call_lines(node) }
        end
        (node.children || []).each { |child| collect_nested_async(child, operations) }
      end

      # Handle :if nodes - extract conditional with then/else branches.
      def handle_conditional(node, operations)
        then_ops = []
        else_ops = []

        # children[0] = condition, children[1] = then, children[2] = else
        children = node.children || []
        walk_predicate(children[0], operations)
        walk(children[1], then_ops) if children[1].is_a?(Ast::Node)
        walk(children[2], else_ops) if children[2].is_a?(Ast::Node)

        return if then_ops.empty? && else_ops.empty?

        operations << {
          type: :conditional,
          kind: 'if',
          condition: condition_source(children[0]) || node.source,
          line: node.line,
          then_ops: then_ops,
          else_ops: else_ops
        }
      end

      # Handle :case nodes as a conditional variant.
      #
      # A case node is `(case predicate when… else)`, so children[0] is the
      # predicate and the branches follow it. Walking *all* children counted
      # any call in the predicate — `case user.role` — as an operation
      # performed inside a branch, and reporting `node.source` as the condition
      # meant the whole multi-line statement stood in for the one expression
      # being switched on. Mirrors {#handle_conditional}.
      def handle_case(node, operations)
        children = node.children || []
        walk_predicate(children[0], operations)
        branch_ops = []
        children.drop(1).each { |child| walk(child, branch_ops) if child.is_a?(Ast::Node) }

        return if branch_ops.empty?

        operations << {
          type: :conditional,
          kind: 'case',
          condition: condition_source(children[0]) || node.source,
          line: node.line,
          then_ops: branch_ops,
          else_ops: []
        }
      end

      # Walk a conditional's predicate into the enclosing operations, ahead
      # of the conditional itself: it runs before either branch, whichever
      # is taken (`if @widget.save`, `case Router.pick(request)`).
      #
      # @param predicate [Ast::Node, String, nil]
      # @param operations [Array<Hash>] the conditional's own level
      def walk_predicate(predicate, operations)
        walk(predicate, operations) if predicate.is_a?(Ast::Node)
      end

      # Source text for a conditional's predicate child, which the parser may
      # hand back as a node or as an already-rendered string.
      #
      # @param child [Ast::Node, String, nil]
      # @return [String, nil]
      def condition_source(child)
        return child.to_source if child.is_a?(Ast::Node)

        child if child.is_a?(String)
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
        RESPONSE_METHODS.include?(node.method_name) || node.method_name&.start_with?('render')
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
