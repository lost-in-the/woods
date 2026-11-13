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
  # `instance` and one `singleton` entry. Statements apply in order, so the
  # table holds one entry per method and side: the definition Ruby calls.
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
    # `public_class_method`, bare or with definitions or names. A `def`
    # written as the argument is defined first, as a plain `def` at that
    # point; the call then receives the name `def` returns and acts on
    # whatever method of that name is held, as it would for `:name`.
    module VisibilityCalls
      private

      # `private` alone changes the default; `private def x` and `private :x`
      # mark only the named methods.
      def visibility_call(node, owner, scope, state)
        arguments = node.arguments&.arguments.to_a
        if arguments.empty?
          state[:module_function] = node.name == :module_function
          state[:visibility] = node.name == :module_function ? 'public' : node.name.to_s
          return []
        end
        return module_function_call(arguments, owner, scope, state) if node.name == :module_function

        visibility = node.name.to_s
        arguments.flat_map do |argument|
          if argument.is_a?(Prism::DefNode)
            next inline_definition(argument, owner, scope, state) do |name|
              Marks.visibility(@entries, [name], owner, scope, visibility)
            end
          end

          @entries = Marks.visibility(@entries, Names.symbol_names(argument), owner, scope, visibility)
          []
        end
      end

      # `module_function def x` and `module_function :x, 'y'` (symbols and
      # strings only; Ruby refuses an array).
      def module_function_call(arguments, owner, scope, state)
        arguments.flat_map do |argument|
          if argument.is_a?(Prism::DefNode)
            next inline_definition(argument, owner, scope, state) do |name|
              scope == 'instance' ? Marks.module_functions(@entries, [name], owner) : @entries
            end
          end

          names = Names.symbol_names(argument) unless argument.is_a?(Prism::ArrayNode)
          @entries = Marks.module_functions(@entries, Array(names), owner) if scope == 'instance'
          []
        end
      end

      # `private_class_method def self.x` and `private_class_method :x, ...`
      # (and `public_class_method`): the visibility of singleton methods
      # already defined; the usual form follows the definition.
      def class_method_visibility(node, owner, state)
        visibility = CLASS_METHOD_VISIBILITY.fetch(node.name)
        node.arguments&.arguments.to_a.flat_map do |argument|
          unless argument.is_a?(Prism::DefNode)
            @entries = Marks.visibility(@entries, Names.symbol_names(argument), owner, 'singleton', visibility)
            next []
          end

          inline_definition(argument, owner, 'instance', state) do |name|
            Marks.visibility(@entries, [name], owner, 'singleton', visibility)
          end
        end
      end

      # @yieldparam name [String] the name the `def` returns
      # @yieldreturn [Array<Hash>] the entries the call leaves
      # @return [Array] nothing more to place
      def inline_definition(node, owner, scope, state)
        entry = plain_definition(node, owner, scope, state)
        place(entry) if entry
        @entries = yield(node.name.to_s)
        []
      end
    end

    # One walk of a parsed tree: the qualified owner from the lexical class
    # and module nesting, the default visibility of each body, and the
    # singleton scopes of `def self.`, `class << self` and `class_methods do`.
    #
    # Statements apply in order, as Ruby runs them: an entry is the method
    # Ruby holds once the body has run. A definition replaces the earlier
    # one on the same side (`def a` twice keeps the later), and a call
    # changes what is already defined. A module function holds both sides,
    # so a later definition on one side leaves the copy on the other.
    class Walker
      include VisibilityCalls

      def initialize
        @entries = []
      end

      # @param root [Prism::Node]
      # @return [Array<Hash>]
      def call(root)
        visit_body(root, nil, scope: 'instance')
        @entries.each { |entry| entry.delete(Marks::SCOPE) }
      end

      private

      # +scope+ is where a plain `def` lands: `instance`, `singleton` (the
      # singleton class) or `extension` (a `class_methods do` body: singleton
      # methods of the including class, defined in a module).
      def visit_body(node, owner, scope:)
        statements = node.is_a?(Prism::ProgramNode) ? node.statements&.body : body_statements(node)
        state = { visibility: 'public', module_function: false, scope: scope }
        Array(statements).each do |statement|
          statement_entries(statement, owner, scope, state).each { |entry| place(entry) }
        end
      end

      # Add a definition, replacing what it overwrites in Ruby.
      def place(entry)
        @entries = Marks.replace(@entries, entry)
      end

      def body_statements(node)
        return [] unless node

        node.is_a?(Prism::StatementsNode) ? node.body : [node]
      end

      def statement_entries(node, owner, scope, state)
        case node
        when Prism::DefNode
          [plain_definition(node, owner, scope, state)].compact
        when Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
          nested_body(node, owner)
        when Prism::CallNode
          call_entries(node, owner, scope, state)
        else
          []
        end
      end

      def nested_body(node, owner)
        if node.is_a?(Prism::SingletonClassNode)
          visit_body(node.body, owner, scope: 'singleton') if node.expression.is_a?(Prism::SelfNode)
        else
          inner = Names.qualified(owner, node.constant_path)
          visit_body(node.body, inner, scope: 'instance') if inner
        end
        []
      end

      def call_entries(node, owner, scope, state)
        return [] unless node.receiver.nil?

        name = node.name
        return visibility_call(node, owner, scope, state) if VISIBILITY_CALLS.include?(name)
        return class_methods_block(node, owner) if name == :class_methods && node.block
        return class_method_visibility(node, owner, state) if CLASS_METHOD_VISIBILITY.key?(name) && scope == 'instance'

        []
      end

      # A `def` under the body's current default visibility and
      # `module_function`.
      def plain_definition(node, owner, scope, state)
        visibility = always_private?(node, state) ? 'private' : state[:visibility]
        definition(node, owner, scope, visibility, state[:module_function])
      end

      # A plain `def` of a name Ruby always defines private, outside a
      # singleton class. An explicit `public def initialize` still wins: the
      # call runs after the definition. Under `module_function` the instance
      # side is private anyway and the entry's visibility is the public copy's.
      def always_private?(node, state)
        return false if node.receiver || state[:scope] == 'singleton' || state[:module_function]

        ALWAYS_PRIVATE.include?(node.name.to_s)
      end

      def class_methods_block(node, owner)
        body = node.block.body
        visit_body(body, owner, scope: 'extension') if body
        []
      end

      # Where the definition lands: `def self.x` on the owner's singleton
      # class (or, inside `class_methods do`, the module's own, kept apart).
      def definition_scope(receiver, scope)
        return scope unless receiver

        scope == 'extension' ? 'extension_singleton' : 'singleton'
      end

      def definition_kind(landing, module_function)
        return landing == 'instance' ? 'instance' : 'singleton' unless module_function && landing == 'instance'

        'module_function'
      end

      def definition(node, owner, scope, visibility, module_function)
        return nil unless owner

        receiver = node.receiver
        return nil if receiver && !receiver.is_a?(Prism::SelfNode)

        visibility = 'public' if receiver # `private` does not apply to `def self.x`
        landing = definition_scope(receiver, scope)
        { 'name' => node.name.to_s, 'kind' => definition_kind(landing, module_function),
          'line' => node.location.start_line, 'end_line' => node.location.end_line,
          'visibility' => visibility, 'owner' => owner, Marks::SCOPE => landing }
      end
    end

    # What a call or a definition does to methods already defined in an
    # owner. A module function's entry holds two slots, the private instance
    # method and the singleton copy whose visibility the entry carries.
    module Marks
      # The internal key naming where an entry was defined; removed before
      # the table is returned.
      SCOPE = 'scope'

      module_function

      # @param entry [Hash]
      # @return [Array<String>] the slots the entry's method occupies
      def slots(entry)
        entry['kind'] == 'module_function' ? %w[instance singleton] : [entry[SCOPE]]
      end

      # The entry reduced to the slots it still holds, or nil for none.
      #
      # @param entry [Hash]
      # @param remaining [Array<String>]
      # @return [Hash, nil]
      def narrow(entry, remaining)
        return entry if remaining == slots(entry)
        return nil if remaining.empty?

        side = remaining.first
        visibility = side == 'instance' ? 'private' : entry['visibility']
        entry.merge('kind' => side, 'visibility' => visibility, SCOPE => side)
      end

      # `private :name` applies to a method already defined in this owner and
      # scope; a name declared before its definition is left as the
      # definition reads. On a module function, the singleton side takes the
      # new visibility, and an instance side made public or protected splits
      # the entry.
      #
      # @return [Array<Hash>]
      def visibility(entries, names, owner, scope, visibility)
        entries.flat_map do |entry|
          next [entry] unless names.include?(entry['name']) && entry['owner'] == owner

          side(entry, scope, visibility)
        end
      end

      def side(entry, scope, visibility)
        if entry['kind'] == 'module_function'
          return [entry.merge('visibility' => visibility)] if scope == 'singleton'
          return [entry] if scope != 'instance' || visibility == 'private'

          return [narrow(entry, %w[instance]).merge('visibility' => visibility), narrow(entry, %w[singleton])]
        end
        entry['visibility'] = visibility if entry[SCOPE] == scope
        [entry]
      end

      # Ruby makes the instance method private and copies it, public, onto
      # the singleton class, replacing any singleton method of that name. A
      # name with no instance method yet (Ruby raises) is left.
      #
      # @return [Array<Hash>]
      def module_functions(entries, names, owner)
        names.uniq.reduce(entries) do |held, name|
          source = held.find { |entry| entry.values_at('owner', 'name', SCOPE) == [owner, name, 'instance'] }
          next held unless source # neither an instance method nor a module function

          copy = source.merge('kind' => 'module_function', 'visibility' => 'public')
          replace(held, copy)
        end
      end

      # +entries+ with +entry+ added and what it overwrites removed or narrowed.
      #
      # @return [Array<Hash>]
      def replace(entries, entry)
        taken = slots(entry)
        entries.filter_map do |held|
          next held unless held['owner'] == entry['owner'] && held['name'] == entry['name']

          narrow(held, slots(held) - taken)
        end << entry
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
