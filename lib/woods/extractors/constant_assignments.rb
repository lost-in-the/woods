# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Top-level constant assignments in a file with no class or module body:
    # `Pattern = /.../`, `Gateway::Billing::Countries = %w[...]`.
    #
    # The value kind is read from the syntax, so no application object is
    # touched. Writes inside a class, module, method, or block belong to their
    # enclosing declaration and are not returned.
    class ConstantAssignments
      VALUE_KINDS = {
        Prism::RegularExpressionNode => 'regexp', Prism::InterpolatedRegularExpressionNode => 'regexp',
        Prism::ArrayNode => 'array', Prism::HashNode => 'hash',
        Prism::StringNode => 'string', Prism::InterpolatedStringNode => 'string',
        Prism::SymbolNode => 'symbol', Prism::IntegerNode => 'number', Prism::FloatNode => 'number',
        Prism::RationalNode => 'number', Prism::RangeNode => 'range',
        Prism::TrueNode => 'boolean', Prism::FalseNode => 'boolean', Prism::NilNode => 'nil'
      }.freeze

      # Calls that return their receiver's kind unchanged.
      PASS_THROUGH = %i[freeze dup].freeze

      # @param source [String] Ruby source of one file
      # @return [Array<Hash>] +:identifier+, +:value_kind+, +:line+, +:end_line+ in source order
      def call(source)
        result = Prism.parse(source)
        return [] unless result.success?

        result.value.statements.body.filter_map { |node| assignment(node) }
      end

      private

      def assignment(node)
        identifier = case node
                     when Prism::ConstantWriteNode then node.name.to_s
                     when Prism::ConstantPathWriteNode then node.target.full_name.delete_prefix('::')
                     end
        return unless identifier

        { identifier: identifier, value_kind: value_kind(node.value),
          line: node.location.start_line, end_line: node.location.end_line }
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def value_kind(node)
        node = node.receiver while node.is_a?(Prism::CallNode) && PASS_THROUGH.include?(node.name) && node.receiver
        VALUE_KINDS.find { |type, _kind| node.is_a?(type) }&.last || 'expression'
      end
    end
  end
end
