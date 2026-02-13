# frozen_string_literal: true

module CodebaseIndex
  module Ast
    # Normalized AST node struct used by all consumers.
    #
    # Provides a parser-independent representation of Ruby AST nodes.
    # Both Prism and the parser gem are normalized to this common structure.
    #
    # @example Creating a send node
    #   node = Ast::Node.new(
    #     type: :send,
    #     children: [],
    #     line: 42,
    #     receiver: "User",
    #     method_name: "find",
    #     arguments: ["id"]
    #   )
    #
    Node = Struct.new(
      :type,        # Symbol: :send, :block, :if, :def, :defs, :class, :module, :const, :begin, etc.
      :children,    # Array<Ast::Node | String | Symbol | Integer | nil>
      :line,        # Integer: 1-based source line number
      :receiver,    # String | nil: method call receiver (for :send)
      :method_name, # String | nil: method name (for :send, :def, :defs)
      :arguments,   # Array<String>: argument representations (for :send)
      :source,      # String | nil: raw source text of this node
      :end_line,    # Integer | nil: 1-based end line number (when available)
      keyword_init: true
    ) do
      # Find all descendant nodes matching a type.
      #
      # @param target_type [Symbol] The node type to search for
      # @return [Array<Ast::Node>] All matching descendant nodes
      def find_all(target_type)
        results = []
        queue = [self]
        while (current = queue.shift)
          results << current if current.type == target_type
          (current.children || []).each do |child|
            queue << child if child.is_a?(Ast::Node)
          end
        end
        results
      end

      # Find the first descendant node matching a type (depth-first).
      #
      # @param target_type [Symbol] The node type to search for
      # @return [Ast::Node, nil] The first matching node or nil
      def find_first(target_type)
        return self if type == target_type

        (children || []).each do |child|
          next unless child.is_a?(Ast::Node)

          result = child.find_first(target_type)
          return result if result
        end
        nil
      end

      # Return source text representation.
      #
      # @return [String] The source field if present, otherwise a reconstruction
      def to_source
        return source if source

        case type
        when :send
          parts = []
          parts << receiver if receiver
          parts << method_name if method_name
          parts.join('.')
        when :const
          parts = []
          parts << receiver if receiver
          parts << method_name if method_name
          parts.join('::')
        when :def, :defs
          "def #{method_name}"
        else
          type.to_s
        end
      end
    end
  end
end
