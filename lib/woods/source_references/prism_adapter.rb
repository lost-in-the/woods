# frozen_string_literal: true

require 'prism'

module Woods
  module SourceReferences
    # Retains AST context that the general Woods flow AST intentionally omits.
    class PrismAdapter
      KINDS = { class_node: :declaration, module_node: :declaration, constant_read_node: :constant,
                constant_path_node: :constant, singleton_class_node: :singleton, def_node: :method }.freeze
      CONSTANT_WRITES = %i[
        constant_write_node constant_path_write_node constant_operator_write_node constant_path_operator_write_node
        constant_and_write_node constant_path_and_write_node constant_or_write_node constant_path_or_write_node
      ].freeze
      DYNAMIC_BLOCK_METHODS = %i[class_eval module_eval instance_eval class_exec module_exec instance_exec].freeze

      def parse(source)
        result = Prism.parse(source)
        error = result.errors.first
        [result.value, error && { 'message' => error.message, 'line' => error.location.start_line }]
      end

      def kind(node)
        return KINDS[node.type] if KINDS.key?(node.type)

        case node.type
        when :constant_write_node, :constant_path_write_node then value_constructor(node) ? :value_class : :other
        when :call_node then dynamic_scope?(node) ? :dynamic_scope : :other
        else :other
        end
      end

      def constant_name(node)
        return unless node
        return node.name.to_s if node.type == :constant_read_node
        return unless node.type == :constant_path_node

        parent = node.parent ? constant_name(node.parent) : ''
        name = node.respond_to?(:name) ? node.name : node.child.name
        "#{parent}::#{name}" if parent
      end

      def children(node)
        return [node.value].compact if CONSTANT_WRITES.include?(node.type)
        return [] if %i[constant_target_node constant_path_target_node].include?(node.type)
        return [node.value].compact if node.type == :multi_write_node
        return [node.parameters, node.body].compact if node.type == :def_node

        node.compact_child_nodes
      end

      def value_constructor(node)
        call = node.value
        return unless call&.type == :call_node

        name = constant_name(call.receiver)
        name if { new: %w[Struct ::Struct], define: %w[Data ::Data] }.fetch(call.name, []).include?(name)
      end

      def assignment_name(node)
        node.type == :constant_write_node ? node.name.to_s : constant_name(node.target)
      end

      def declaration_name(node)
        constant_name(node.constant_path)
      end

      def declaration_kind(node)
        node.type == :class_node ? 'class' : 'module'
      end

      def superclass(node)
        node.superclass if node.type == :class_node
      end

      def body(node)
        node.body
      end

      def self_receiver?(node)
        node.expression.type == :self_node
      end

      def local_method?(node)
        node.receiver.nil? || node.receiver.type == :self_node
      end

      def line(node)
        node.location.start_line
      end

      def end_line(node)
        node.location.end_line
      end

      private

      def dynamic_scope?(node)
        return false unless node.block&.type == :block_node
        return true if DYNAMIC_BLOCK_METHODS.include?(node.name)

        foreign_method?(node) || anonymous_class?(node.name, node.receiver)
      end

      def foreign_method?(node)
        %i[define_method define_singleton_method].include?(node.name) &&
          node.receiver && node.receiver.type != :self_node
      end

      def anonymous_class?(method, receiver)
        name = constant_name(receiver)&.delete_prefix('::')
        { new: %w[Class Module Struct], define: ['Data'] }.fetch(method, []).include?(name)
      end
    end
  end
end
