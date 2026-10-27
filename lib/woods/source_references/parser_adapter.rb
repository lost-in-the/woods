# frozen_string_literal: true

module Woods
  module SourceReferences
    # Optional parser-gem backend with the same ownership rules as Prism.
    class ParserAdapter # rubocop:disable Metrics/ClassLength -- keep backend coordinate conversion with parsing
      KINDS = { class: :declaration, module: :declaration, const: :constant, sclass: :singleton,
                def: :method, defs: :method }.freeze
      DYNAMIC_BLOCK_METHODS = %i[class_eval module_eval instance_eval class_exec module_exec instance_exec].freeze

      def parse(source)
        require 'parser/current' unless defined?(::Parser::CurrentRuby)
        parser = ::Parser::CurrentRuby.default_parser
        diagnostics = []
        parser.diagnostics.consumer = ->(diagnostic) { diagnostics << diagnostic }
        parser.diagnostics.all_errors_are_fatal = true
        parser.diagnostics.ignore_warnings = true
        buffer = source_buffer(source)
        [parser.parse(buffer), nil]
      rescue ::Parser::SyntaxError => e
        diagnostic = diagnostics.last
        [nil, { 'message' => e.message, 'line' => diagnostic&.location&.line || 1 }]
      end

      def kind(node)
        return KINDS[node.type] if KINDS.key?(node.type)

        case node.type
        when :casgn then value_constructor(node) ? :value_class : :other
        when :block, :numblock then dynamic_scope?(node) ? :dynamic_scope : :other
        when :send, :csend then :call
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

      def receiver(node)
        node.children.first
      end

      def selector(node)
        node.children[1]
      end

      def constant_receiver(node)
        candidate = receiver(node)
        candidate = candidate.children.first while candidate&.type == :begin && candidate.children.one?
        candidate if candidate&.type == :const
      end

      # @return [Array<Parser::AST::Node>] the arguments written directly in the call
      def arguments(node)
        node.children.drop(2).grep(::Parser::AST::Node)
      end

      def children(node)
        nodes = case node.type
                when :casgn then [node.children[2]]
                when :masgn then [node.children[1]]
                when :defs then node.children.drop(2)
                when :op_asgn, :and_asgn, :or_asgn then compound_children(node)
                when :resbody then assignment_children(node, 1)
                when :for then assignment_children(node, 0)
                else node.children
                end
        nodes.grep(::Parser::AST::Node)
      end

      def value_constructor(node)
        call = node.children[2]
        return unless call

        call = call.children.first if %i[block numblock].include?(call.type)
        return unless call.type == :send

        receiver, method = call.children
        name = constant_name(receiver)
        name if { new: %w[Struct ::Struct], define: %w[Data ::Data] }.fetch(method, []).include?(name)
      end

      def assignment_name(node)
        parent, name = node.children
        prefix = parent ? constant_name(parent) : nil
        return if parent && !prefix

        [prefix, name.to_s].compact.join('::')
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

      # Parser ranges count characters and normalize CRLF. Convert both ends
      # against the untouched input, so both backends publish original bytes.
      # @return [Hash] 1-based line, 0-based UTF-8 byte column and byte length
      def position(node)
        range = node.location.expression
        first = byte_offset(range.line, range.column)
        last = byte_offset(range.last_line, range.last_column)
        { 'line' => range.line, 'column' => first - @line_offsets[range.line - 1], 'length' => last - first }
      end

      def line(node)
        node.location.expression.line
      end

      # @return [Array<Array(String, Hash)>] literal symbol arguments before the
      #   first other argument, each with the position of the whole `:name`
      def leading_symbols(node)
        node.children.drop(2).take_while { |argument| argument.is_a?(::Parser::AST::Node) && argument.type == :sym }
            .filter_map do |symbol|
          name = symbol.children.first.to_s
          [name, position(symbol)] unless name.empty? || symbol.location.begin.nil?
        end
      end

      def end_line(node)
        node.location.expression.last_line
      end

      private

      # Rescue/for targets are assignment evidence, not explicit call sites.
      # Match Prism's target nodes while keeping their receivers and index
      # arguments available to the ordinary call traversal.
      def assignment_children(node, position)
        node.children.each_with_index.flat_map do |child, index|
          index == position ? assignment_target(child) : [child]
        end
      end

      def assignment_target(node)
        return [node] unless node
        return node.children if %i[send csend].include?(node.type)
        return node.children.flat_map { |child| assignment_target(child) } if %i[mlhs splat].include?(node.type)

        [node]
      end

      # A compound write can dispatch both a getter and setter. Prism exposes
      # their receiver directly; flatten Parser's getter to retain the same
      # constant spans without claiming one selector represents the operation.
      def compound_children(node)
        getter, *rest = node.children
        return node.children unless getter && %i[send csend].include?(getter.type)

        [*getter.children, *rest]
      end

      def source_buffer(source)
        # Source::Buffer honors an encoding magic comment, and otherwise Ruby
        # defaults to UTF-8 even when the captured input is binary-tagged.
        input = source.dup
        input.force_encoding(Encoding::UTF_8) if input.encoding == Encoding::BINARY
        encoding = ::Parser::Source::Buffer.recognize_encoding(input.b) || input.encoding
        @source_lines = input.dup.force_encoding(encoding).lines
        @line_offsets = [0]
        @source_lines.each { |text| @line_offsets << (@line_offsets.last + text.bytesize) }
        ::Parser::Source::Buffer.new('(source references)', source: input)
      end

      def byte_offset(line, column)
        @line_offsets.fetch(line - 1) + @source_lines.fetch(line - 1)[0, column].bytesize
      end

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
