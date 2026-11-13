# frozen_string_literal: true

require 'prism'
require_relative 'parse_cache'
require_relative 'file_lines'

module Woods
  # Method definitions in a unit's published `source_code` (#752): name, kind,
  # line range, visibility and owner. `line`/`end_line` are in annotated-source
  # coordinates (the same as `metadata.references`); `file_line`/`file_end_line`
  # give the line in the file a reader opens, and `file_unit` names the concern
  # whose file that is for a definition inside an inlined block ({FileLines}).
  #
  # Definitions come from one Prism walk of the published text. Concern
  # source that an extractor inlined as a commented display block is decoded
  # from that block and walked separately, so its definitions keep their
  # concern owner and their lines point into the block. Nothing is executed:
  # kind and visibility follow what Ruby reports for each definition, read
  # from the literal forms in the body (`private`/`protected`/`public`,
  # `module_function`, `private_class_method`/`public_class_method`, and the
  # names Ruby always defines private), and a method defined by
  # metaprogramming is absent. A `module_function` entry stands for a private
  # instance method and a singleton copy of the entry's visibility; a later
  # call that makes the instance side public or protected splits it into one
  # `instance` and one `singleton` entry.
  module MethodTable
    # Unit types whose source is a class or module body.
    TYPES = %w[model controller service job mailer concern poro lib manager policy validator serializer
               decorator pundit_policy component view_component action_cable_channel graphql_type
               graphql_mutation graphql_resolver graphql_query].freeze

    VISIBILITY = %i[public private protected].freeze
    VISIBILITY_CALLS = [*VISIBILITY, :module_function].freeze

    # Instance methods Ruby defines private wherever `def` is written, unless
    # the definition is on a singleton class (vm_method.c, rb_method_entry_make).
    ALWAYS_PRIVATE = %w[initialize initialize_copy initialize_clone initialize_dup respond_to_missing?].freeze

    CLASS_METHOD_VISIBILITY = { private_class_method: 'private', public_class_method: 'public' }.freeze

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
        locator = FileLines.for(unit)
        unit.metadata[:methods] = table.each { |entry| locator.annotate(entry) }
      else
        unit.metadata.delete(:methods)
      end
    end

    # @param source [String, nil] published annotated source
    # @return [Array<Hash>, nil] string-keyed entries sorted by line and name,
    #   or nil when the source is absent or does not parse
    def call(source)
      return nil unless source.is_a?(String) && !source.empty?

      result = Woods::ParseCache.parse(source)
      return nil if result.errors.any?

      entries = Walker.new.call(result.value)
      entries.concat(concern_entries(source))
      entries.sort_by { |entry| entry.values_at('line', 'end_line', 'name', 'owner', 'kind') }
    end

    # Definitions inside the commented concern blocks of composite sources.
    # A block whose decoded text does not parse contributes nothing.
    def concern_entries(source)
      blocks(source.lines(chomp: true)).flat_map do |first_line, text|
        parsed = Woods::ParseCache.parse(text)
        next [] if parsed.errors.any?

        Walker.new.call(parsed.value).map do |entry|
          entry.merge('line' => entry['line'] + first_line - 1, 'end_line' => entry['end_line'] + first_line - 1)
        end
      end
    end

    # @return [Array<Array(Integer, String)>] the first code line of each
    #   block and its decoded Ruby; the frame's two closing lines follow the header
    def blocks(lines)
      named_blocks(lines).map { |first_line, text, _name| [first_line, text] }
    end

    # @return [Array<Array(Integer, Integer, String)>] each block's first and
    #   last code line in the annotated source and the concern it was inlined
    #   from
    def block_ranges(lines)
      named_blocks(lines).map { |first_line, text, name| [first_line, first_line + text.count("\n"), name] }
    end

    # @return [Array<Array(Integer, String, String)>] first code line, decoded
    #   Ruby and concern name of each block
    def named_blocks(lines)
      found = []
      index = 0
      while index < lines.size
        name = lines[index][BLOCK_HEADER, 1]
        block, index = name ? block_after(lines, index, name.strip) : [nil, index + 1]
        found << [*block, name.strip] if block
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

    # The visibility calls of a body, for {Walker}: `private`, `protected`,
    # `public`, `module_function`, `private_class_method` and
    # `public_class_method`, bare or with definitions or names.
    module VisibilityCalls
      private

      # `private` alone changes the default; `private def x` and `private :x`
      # mark only the named methods.
      def visibility_call(node, owner, singleton, state)
        arguments = node.arguments&.arguments.to_a
        if arguments.empty?
          state[:module_function] = node.name == :module_function
          state[:visibility] = node.name == :module_function ? 'public' : node.name.to_s
          return []
        end
        return module_function_call(arguments, owner, singleton) if node.name == :module_function

        visibility = node.name.to_s
        arguments.flat_map do |argument|
          if argument.is_a?(Prism::DefNode)
            [definition(argument, owner, singleton, visibility, false)].compact
          else
            @entries = Marks.visibility(@entries, Names.symbol_names(argument), owner, singleton, visibility)
            []
          end
        end
      end

      # `module_function def x` and `module_function :x, 'y'` (symbols and
      # strings only; Ruby refuses an array).
      def module_function_call(arguments, owner, singleton)
        arguments.flat_map do |argument|
          next [definition(argument, owner, singleton, 'public', true)].compact if argument.is_a?(Prism::DefNode)

          names = Names.symbol_names(argument) unless argument.is_a?(Prism::ArrayNode)
          @entries = Marks.module_functions(@entries, Array(names), owner) unless singleton
          []
        end
      end

      # `private_class_method def self.x` and `private_class_method :x, ...`
      # (and `public_class_method`): the visibility of singleton methods
      # already defined; the usual form follows the definition.
      def class_method_visibility(node, owner)
        visibility = CLASS_METHOD_VISIBILITY.fetch(node.name)
        node.arguments&.arguments.to_a.flat_map do |argument|
          unless argument.is_a?(Prism::DefNode)
            @entries = Marks.visibility(@entries, Names.symbol_names(argument), owner, true, visibility)
            next []
          end

          entry = definition(argument, owner, false, 'public', false)
          entry['visibility'] = visibility if entry && entry['kind'] == 'singleton'
          [entry].compact
        end
      end
    end

    # One walk of a parsed tree: the qualified owner from the lexical class
    # and module nesting, the default visibility of each body, and the
    # singleton scopes of `def self.`, `class << self` and `class_methods do`.
    class Walker
      include VisibilityCalls

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

      # +extension+ marks a `class_methods do` body: its definitions are
      # singleton methods of the including class, but Ruby defines them in a
      # module, not a singleton class.
      def visit_body(node, owner, singleton:, extension: false)
        statements = node.is_a?(Prism::ProgramNode) ? node.statements&.body : body_statements(node)
        state = { visibility: 'public', module_function: false, singleton_class: singleton && !extension }
        Array(statements).each do |statement|
          found = statement_entries(statement, owner, singleton, state) # may replace @entries
          @entries.concat(found)
        end
      end

      def body_statements(node)
        return [] unless node

        node.is_a?(Prism::StatementsNode) ? node.body : [node]
      end

      def statement_entries(node, owner, singleton, state)
        case node
        when Prism::DefNode
          visibility = always_private?(node, state) ? 'private' : state[:visibility]
          [definition(node, owner, singleton, visibility, state[:module_function])].compact
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          nested_body(node, owner)
        when Prism::CallNode
          call_entries(node, owner, singleton, state)
        else
          []
        end
      end

      def nested_body(node, owner)
        if node.is_a?(Prism::SingletonClassNode)
          visit_body(node.body, owner, singleton: true) if node.expression.is_a?(Prism::SelfNode)
        else
          inner = Names.qualified(owner, node.constant_path)
          visit_body(node.body, inner, singleton: false) if inner
        end
        []
      end

      def call_entries(node, owner, singleton, state)
        return [] unless node.receiver.nil?

        name = node.name
        return visibility_call(node, owner, singleton, state) if VISIBILITY_CALLS.include?(name)
        return class_methods_block(node, owner) if name == :class_methods && node.block
        return class_method_visibility(node, owner) if CLASS_METHOD_VISIBILITY.key?(name) && !singleton

        []
      end

      # A plain `def` of a name Ruby always defines private, outside a
      # singleton class. An explicit `public def initialize` still wins: the
      # call runs after the definition. Under `module_function` the instance
      # side is private anyway and the entry's visibility is the public copy's.
      def always_private?(node, state)
        return false if node.receiver || state[:singleton_class] || state[:module_function]

        ALWAYS_PRIVATE.include?(node.name.to_s)
      end

      def class_methods_block(node, owner)
        body = node.block.body
        visit_body(body, owner, singleton: true, extension: true) if body
        []
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

    # Calls that change methods already defined in an owner. Each returns
    # the entries to keep.
    module Marks
      module_function

      # `private :name` applies to a method already defined in this owner; a
      # name declared before its definition is left as the definition reads.
      # A module function's entry carries its singleton side's visibility and
      # a private instance side: the singleton side takes the new visibility,
      # and an instance side made public or protected splits the entry.
      #
      # @return [Array<Hash>]
      def visibility(entries, names, owner, singleton, visibility)
        entries.flat_map do |entry|
          next [entry] unless names.include?(entry['name']) && entry['owner'] == owner

          side(entry, singleton, visibility)
        end
      end

      def side(entry, singleton, visibility)
        if entry['kind'] == 'module_function'
          return [entry.merge('visibility' => visibility)] if singleton
          return [entry] if visibility == 'private'

          return [entry.merge('kind' => 'instance', 'visibility' => visibility), entry.merge('kind' => 'singleton')]
        end
        entry['visibility'] = visibility if entry['kind'] == (singleton ? 'singleton' : 'instance')
        [entry]
      end

      # Ruby makes the instance method private and copies it, public, onto
      # the singleton class. A name not yet defined (Ruby raises) is left.
      #
      # @return [Array<Hash>]
      def module_functions(entries, names, owner)
        entries.each do |entry|
          next unless names.include?(entry['name']) && entry['owner'] == owner
          next unless %w[instance module_function].include?(entry['kind'])

          entry['kind'] = 'module_function'
          entry['visibility'] = 'public'
        end
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
