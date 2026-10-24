# frozen_string_literal: true

require 'prism'

module Woods
  # Method definitions in a unit's published `source_code` (#752): name, kind,
  # line range, visibility and owner, in annotated-source coordinates (the
  # same coordinates as `metadata.references`; `source_line_map` translates
  # them to the primary file).
  #
  # Definitions come from one Prism walk of the published text. Concern
  # source that an extractor inlined as a commented display block is decoded
  # from that block and walked separately, so its definitions keep their
  # concern owner and their lines point into the block. Nothing is executed:
  # visibility follows the literal `private`/`protected`/`public` forms in
  # the class body, and a method defined by metaprogramming is absent.
  module MethodTable
    # Unit types whose source is a class or module body.
    TYPES = %w[model controller service job mailer concern poro lib manager policy validator serializer
               decorator pundit_policy component view_component action_cable_channel graphql_type
               graphql_mutation graphql_resolver graphql_query].freeze

    VISIBILITY = %i[public private protected].freeze

    BLOCK_HEADER = /\A# │ Included from: (.+?)[^\S\n]*│\z/
    BLOCK_FOOTER = /\A# ─+ End (.+?) ─+\z/
    BLOCK_LINE = /\A  # ?(.*)\z/m

    module_function

    # Record the table on a unit about to be written. A unit whose source does
    # not parse keeps no table: absence means unavailable, never "no methods".
    #
    # @param unit [ExtractedUnit]
    # @return [void]
    def record(unit)
      return unless TYPES.include?(unit.type.to_s)

      table = call(unit.source_code)
      if table
        unit.metadata[:methods] = table
      else
        unit.metadata.delete(:methods)
      end
    end

    # @param source [String, nil] published annotated source
    # @return [Array<Hash>, nil] string-keyed entries sorted by line and name,
    #   or nil when the source is absent or does not parse
    def call(source)
      return nil unless source.is_a?(String) && !source.empty?

      result = Prism.parse(source)
      return nil if result.errors.any?

      entries = Walker.new.call(result.value)
      entries.concat(concern_entries(source))
      entries.sort_by { |entry| entry.values_at('line', 'end_line', 'name', 'owner') }
    end

    # Definitions inside the commented concern blocks of composite sources.
    # A block whose decoded text does not parse contributes nothing.
    def concern_entries(source)
      blocks(source.lines(chomp: true)).flat_map do |first_line, text|
        parsed = Prism.parse(text)
        next [] if parsed.errors.any?

        Walker.new.call(parsed.value).map do |entry|
          entry.merge('line' => entry['line'] + first_line - 1, 'end_line' => entry['end_line'] + first_line - 1)
        end
      end
    end

    # @return [Array<Array(Integer, String)>] the first code line of each
    #   block and its decoded Ruby; the frame's two closing lines follow the header
    def blocks(lines)
      found = []
      index = 0
      while index < lines.size
        name = lines[index][BLOCK_HEADER, 1]
        block, index = name ? block_after(lines, index, name.strip) : [nil, index + 1]
        found << block if block
      end
      found
    end

    # The block whose header is at +index+: [first code line, decoded Ruby]
    # and the index to resume at, or nil for an unterminated or altered block.
    def block_after(lines, index, name)
      start = index + 2 # past the header and the closing frame line
      finish = (start...lines.size).find { |i| lines[i][BLOCK_FOOTER, 1]&.strip == name }
      return [nil, index + 1] unless finish

      decoded = lines[start...finish].map { |line| line[BLOCK_LINE, 1] }
      [decoded.none?(&:nil?) ? [start + 1, decoded.join("\n")] : nil, finish + 1]
    end

    # One walk of a parsed tree: the qualified owner from the lexical class
    # and module nesting, the default visibility of each body, and the
    # singleton scopes of `def self.`, `class << self` and `class_methods do`.
    class Walker
      def initialize
        @entries = []
      end

      # @param root [Prism::Node]
      # @return [Array<Hash>]
      def call(root)
        visit_body(root, nil, singleton: false)
        @entries
      end

      private

      def visit_body(node, owner, singleton:)
        statements = node.is_a?(Prism::ProgramNode) ? node.statements&.body : body_statements(node)
        state = { visibility: 'public', module_function: false }
        Array(statements).each do |statement|
          @entries.concat(statement_entries(statement, owner, singleton, state))
        end
      end

      def body_statements(node)
        return [] unless node

        node.is_a?(Prism::StatementsNode) ? node.body : [node]
      end

      def statement_entries(node, owner, singleton, state)
        case node
        when Prism::DefNode
          [definition(node, owner, singleton, state[:visibility], state[:module_function])].compact
        when Prism::ClassNode, Prism::ModuleNode
          inner = Names.qualified(owner, node.constant_path)
          visit_body(node.body, inner, singleton: false) if inner
          []
        when Prism::SingletonClassNode
          visit_body(node.body, owner, singleton: true) if node.expression.is_a?(Prism::SelfNode)
          []
        when Prism::CallNode
          call_entries(node, owner, singleton, state)
        else
          []
        end
      end

      def call_entries(node, owner, singleton, state)
        return [] unless node.receiver.nil?

        if VISIBILITY.include?(node.name) || node.name == :module_function
          return visibility_call(node, owner, singleton, state)
        end
        return class_methods_block(node, owner) if node.name == :class_methods && node.block
        return private_class_method(node, owner) if node.name == :private_class_method

        []
      end

      # `private` alone changes the default; `private def x` and `private :x`
      # mark only the named methods.
      def visibility_call(node, owner, singleton, state)
        arguments = node.arguments&.arguments.to_a
        if arguments.empty?
          state[:module_function] = node.name == :module_function
          state[:visibility] = node.name == :module_function ? 'public' : node.name.to_s
          return []
        end
        visibility = node.name == :module_function ? 'public' : node.name.to_s
        arguments.flat_map do |argument|
          if argument.is_a?(Prism::DefNode)
            [definition(argument, owner, singleton, visibility, node.name == :module_function)].compact
          else
            mark(Names.symbol_names(argument), owner, singleton, visibility)
            []
          end
        end
      end

      # Marks singleton methods already defined; the usual form follows the definition.
      def private_class_method(node, owner)
        names = node.arguments&.arguments.to_a.flat_map { |argument| Names.symbol_names(argument) }
        mark(names, owner, true, 'private')
        []
      end

      def class_methods_block(node, owner)
        body = node.block.body
        visit_body(body, owner, singleton: true) if body
        []
      end

      # `private :name` applies to a method already defined in this owner; a
      # name declared before its definition is left as the definition reads.
      def mark(names, owner, singleton, visibility)
        kind = singleton ? 'singleton' : 'instance'
        @entries.each do |entry|
          next unless names.include?(entry['name']) && entry['owner'] == owner && entry['kind'] == kind

          entry['visibility'] = visibility
        end
      end

      def definition_kind(receiver, singleton, module_function)
        return 'module_function' if module_function

        singleton || receiver ? 'singleton' : 'instance'
      end

      def definition(node, owner, singleton, visibility, module_function)
        return nil unless owner

        receiver = node.receiver
        return nil if receiver && !receiver.is_a?(Prism::SelfNode)

        visibility = 'public' if receiver # `private` does not apply to `def self.x`
        { 'name' => node.name.to_s, 'kind' => definition_kind(receiver, singleton, module_function),
          'line' => node.location.start_line,
          'end_line' => node.location.end_line, 'visibility' => visibility, 'owner' => owner }
      end
    end

    # Literal constant and symbol names, read without evaluation.
    module Names
      module_function

      def qualified(owner, path)
        name = constant_name(path)
        return nil unless name
        return name.delete_prefix('::') if name.start_with?('::')

        owner ? "#{owner}::#{name}" : name
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? constant_name(node.parent) : ''
          "#{parent}::#{node.name}" if parent
        end
      end

      def symbol_names(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then [node.unescaped.to_s]
        when Prism::ArrayNode then node.elements.flat_map { |element| symbol_names(element) }
        else []
        end
      end
    end
  end
end
