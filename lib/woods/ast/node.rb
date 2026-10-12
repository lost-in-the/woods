# frozen_string_literal: true

module Woods
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
      :start_byte,   # Integer | nil: inclusive byte offset into the parsed source
      :end_byte,     # Integer | nil: exclusive byte offset into the parsed source
      :message_line, # Integer | nil: line of a call's method name (for :send)
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

    # One source split into lines once, with byte positions derived on demand.
    #
    # @api private
    class LineTable
      # @return [String] the source this table was built from
      attr_reader :source

      # @return [Array<String>] the source's lines, terminators included
      attr_reader :lines

      # @param source [String]
      def initialize(source)
        @source = source
        @lines = source.lines
      end

      # @param index [Integer] 0-based line index
      # @return [Integer] byte offset of the line's first byte
      # @raise [IndexError] when the line does not exist
      def byte_start(index)
        @byte_starts ||= begin
          total = 0
          @lines.map { |line| (total += line.bytesize) - line.bytesize }
        end
        @byte_starts.fetch(index)
      end

      # @param index [Integer] 0-based line index
      # @param column [Integer] 0-based character column, clamped to the line
      # @return [Integer] bytes the line spends before that column
      # @raise [IndexError] when the line does not exist
      def byte_column(index, column)
        line = @lines.fetch(index)
        return [column, line.bytesize].min if line.ascii_only?

        offsets = (@column_bytes ||= {})[index] ||= character_byte_offsets(line)
        offsets[[column, offsets.size - 1].min]
      end

      private

      def character_byte_offsets(line)
        total = 0
        line.each_char.map { |char| (total += char.bytesize) - char.bytesize } << total
      end
    end

    # Mixin for line-range source extraction, shared across Parser, MethodExtractor,
    # and ClassAnalyzer.
    #
    # @example
    #   include Ast::SourceSpan
    #   with_source_lines(source) { extract_source_span(source, node.line, node.end_line) }
    #
    module SourceSpan
      LINE_TABLE_KEY = :woods_ast_source_span_line_table
      private_constant :LINE_TABLE_KEY

      private

      # Split +source+ once for every span requested inside the block. A walk
      # asks for one span per definition; splitting per request is quadratic
      # in the file. Scoped to the block and the calling thread, so a string
      # edited between calls is never read through a stale table.
      #
      # @param source [String] Full source text
      # @yield the walk that requests spans of +source+
      # @return [Object] the block's value
      def with_source_lines(source)
        previous = Thread.current[LINE_TABLE_KEY]
        return yield if previous&.source.equal?(source)

        Thread.current[LINE_TABLE_KEY] = LineTable.new(source)
        begin
          yield
        ensure
          Thread.current[LINE_TABLE_KEY] = previous
        end
      end

      # @param source [String] Full source text
      # @return [LineTable] the enclosing {#with_source_lines} table, or a fresh one
      def source_line_table(source)
        table = Thread.current[LINE_TABLE_KEY]
        table&.source.equal?(source) ? table : LineTable.new(source)
      end

      # Extract source lines for a 1-based start/end line range.
      #
      # @param source [String] Full source text
      # @param start_line [Integer, nil] 1-based start line
      # @param end_line [Integer, nil] 1-based end line
      # @return [String, nil] Extracted lines joined, or nil if out of range
      def extract_source_span(source, start_line, end_line)
        return nil unless start_line && end_line

        lines = source_line_table(source).lines
        start_idx = start_line - 1
        end_idx = end_line - 1
        return nil if start_idx.negative? || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end
    end
  end
end
