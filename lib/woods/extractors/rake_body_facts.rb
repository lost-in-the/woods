# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # What a rake task body, an +enhance+ block or a helper method does, read
    # from its Prism subtree without running it.
    #
    # @example
    #   block = Prism.parse("task(:a) { sh 'make'; Rake::Task['b'].invoke }").value.statements.body.first.block
    #   RakeBodyFacts.collect(block)
    #   # => { invocations: ["b"], calls: [{ name: "sh", receiver: nil, command: "make" }, ...],
    #   #      commands: [], constants: ["Rake::Task"] }
    module RakeBodyFacts
      # Task methods that run a task from inside another one.
      INVOKERS = %i[invoke execute].freeze

      EMPTY = { invocations: [].freeze, calls: [].freeze, commands: [].freeze, constants: [].freeze }.freeze

      module_function

      # @param node [Prism::Node, nil] a block, a method definition or any subtree
      # @return [Hash{Symbol => Array}] +:invocations+ (task names), +:calls+
      #   (+{ name:, receiver:, command: }+ for receiverless and constant-receiver
      #   calls), +:commands+ (backtick command text) and +:constants+, each in
      #   source order
      def collect(node)
        return EMPTY unless node

        facts = { invocations: [], calls: [], commands: [], constants: [] }
        walk(node, facts)
        facts[:constants].uniq!
        facts
      end

      # The task name in `Rake::Task['name']` or `Rake.application['name']`.
      #
      # @param node [Prism::Node, nil]
      # @return [String, nil] nil unless the node is a lookup with a literal name
      def lookup_target(node)
        return nil unless node.is_a?(Prism::CallNode) && node.name == :[] && task_registry?(node.receiver)

        literal_text(node.arguments&.arguments&.first)
      end

      # @param node [Prism::Node, nil]
      # @return [String, nil] the value of a symbol or string without interpolation
      def literal_text(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped
        when Prism::InterpolatedStringNode
          node.parts.map(&:unescaped).join if node.parts.all?(Prism::StringNode)
        end
      end

      def walk(node, facts)
        case node
        when Prism::CallNode then record_call(node, facts)
        when Prism::XStringNode then facts[:commands] << node.unescaped
        when Prism::InterpolatedXStringNode then facts[:commands] << template_text(node)
        when Prism::ConstantReadNode then facts[:constants] << node.name.to_s
        when Prism::ConstantPathNode
          return facts[:constants] << node.slice.delete_prefix('::') if constant_path?(node)
        end
        node.compact_child_nodes.each { |child| walk(child, facts) }
      end

      def record_call(node, facts)
        invoked = invocation_target(node)
        facts[:invocations] << invoked if invoked
        receiver = constant_name(node.receiver)
        return unless node.receiver.nil? || receiver

        facts[:calls] << { name: node.name.to_s, receiver: receiver, command: command_text(node) }
      end

      def invocation_target(node)
        return lookup_target(node.receiver) if INVOKERS.include?(node.name)
        return nil unless node.name == :invoke_task && rake_application?(node.receiver)

        # `invoke_task` takes "name[arg,arg]".
        literal_text(node.arguments&.arguments&.first)&.split('[', 2)&.first
      end

      def task_registry?(node)
        constant_name(node) == 'Rake::Task' || rake_application?(node)
      end

      def rake_application?(node)
        node.is_a?(Prism::CallNode) && node.name == :application && constant_name(node.receiver) == 'Rake'
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.slice.delete_prefix('::') if constant_path?(node)
        end
      end

      # True when every segment is a constant (`A::B`, not `a::B`).
      def constant_path?(node)
        parent = node.parent
        parent.nil? || parent.is_a?(Prism::ConstantReadNode) ||
          (parent.is_a?(Prism::ConstantPathNode) && constant_path?(parent))
      end

      # The leading string arguments of a call, joined the way a shell would
      # see them. An environment Hash in first position is skipped.
      def command_text(node)
        arguments = node.arguments&.arguments.to_a
        arguments = arguments.drop(1) if arguments.first.is_a?(Prism::HashNode)
        words = arguments.take_while { |argument| string_like?(argument) }.map { |argument| template_text(argument) }
        words.join(' ') unless words.empty?
      end

      def string_like?(node)
        node.is_a?(Prism::StringNode) || node.is_a?(Prism::InterpolatedStringNode)
      end

      # String content with each interpolation kept as written.
      def template_text(node)
        return node.unescaped if node.is_a?(Prism::StringNode)

        node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : part.slice }.join
      end

      private_class_method :walk, :record_call, :invocation_target, :task_registry?, :rake_application?,
                           :constant_path?, :command_text, :string_like?, :template_text
    end
  end
end
