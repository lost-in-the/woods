# frozen_string_literal: true

require_relative '../method_table'
require_relative '../file_lines'
require_relative '../parse_cache'
require 'set'

module Woods
  module MCP
    # One method of a published unit, for a `lookup` of `Owner#method`
    # (instance) or `Owner.method` (class method) that names no unit itself.
    #
    # The method is read from the unit's published method table
    # (`metadata.methods`, #752), which carries its line range in the published
    # source and in the file. A unit published before that table existed is
    # read with {Woods::MethodTable} over its published `source_code`, so the
    # method is found by a Prism walk, never by a pattern over the text. A
    # method inlined from a concern is still a member of the unit; its
    # `file_unit` names the concern whose file it is in.
    module LookupMember
      # A parsed member identifier.
      Reference = Struct.new(:identifier, :owner, :separator, :name, keyword_init: true) do
        # @return [String] "instance method" or "class method"
        def kind_label
          separator == '#' ? 'instance method' : 'class method'
        end

        # @param entry [Hash] a method table entry
        # @return [Boolean] whether the entry is a method of this reference's kind
        def kind?(entry)
          kinds = separator == '#' ? %w[instance module_function] : %w[singleton module_function]
          kinds.include?(entry['kind'])
        end

        # The entry as the method +#+ names it: a `module_function`'s
        # instance side is a private instance method (the published entry
        # describes the public singleton copy). A copy; the published entry
        # is not changed.
        #
        # @param entry [Hash] a method table entry
        # @return [Hash]
        def as_named(entry)
          return entry unless separator == '#' && entry['kind'] == 'module_function'

          entry.merge('kind' => 'instance', 'visibility' => 'private')
        end

        # For a definition inlined from a concern: only what the including
        # class responds to. Instance methods (a `module_function`'s private
        # instance side among them) are mixed in, and the
        # definitions of `class_methods do` are extended onto it; the
        # concern's own `def self.x`, `class << self` and the singleton copy
        # of a `module_function` stay on the concern.
        #
        # @param entry [Hash] a method table entry with `file_unit`
        # @param class_method_lines [Set<Integer>] lines of the concern's
        #   `class_methods` definitions, in published-source coordinates
        # @return [Boolean]
        def concern_kind?(entry, class_method_lines)
          return %w[instance module_function].include?(entry['kind']) if separator == '#'

          entry['kind'] == 'singleton' && class_method_lines.include?(entry['line'])
        end
      end

      # A constant path, `#` or `.`, then a method name (which may end in `?`,
      # `!` or `=`, or be an operator; no name contains `#`, `.` or `:`).
      IDENTIFIER = /\A((?:::)?[A-Z]\w*(?:::[A-Z]\w*)*)([#.])([^\s#.:]+)\z/

      KIND_LABELS = { 'instance' => 'instance method', 'singleton' => 'class method',
                      'module_function' => 'module function' }.freeze

      module_function

      # @param identifier [String]
      # @return [Reference, nil] nil unless the identifier has the member form
      def parse(identifier)
        match = IDENTIFIER.match(identifier.to_s.strip)
        return nil unless match

        Reference.new(identifier: match[0], owner: match[1].delete_prefix('::'), separator: match[2],
                      name: match[3])
      end

      # The member answer for +reference+ in +unit+.
      #
      # @param unit [Hash] the owner's published unit
      # @param reference [Reference]
      # @param concern_file [#call, nil] concern name => its file path, or nil
      # @return [Hash, nil] string-keyed answer, or nil when the unit's
      #   published source holds no such method
      def answer(unit, reference, concern_file: nil)
        entry, others = locate(unit, reference)
        return nil unless entry

        owner = { 'identifier' => unit['identifier'], 'type' => unit['type'], 'file_path' => unit['file_path'] }
        result = { 'identifier' => reference.identifier, 'member_of' => owner,
                   'member' => entry, 'statement' => statement(reference, unit, entry) }
        if entry['file_unit']
          result['defined_in'] = { 'identifier' => entry['file_unit'],
                                   'file_path' => concern_file&.call(entry['file_unit']) }
        end
        result['other_definitions'] = others unless others.empty?
        result['source_code'] = source_text(unit['source_code'], entry)
        result
      end

      # @return [String] the sentence that says what the answer is
      def statement(reference, unit, entry)
        kind = KIND_LABELS.fetch(entry['kind'], reference.kind_label)
        "#{reference.identifier} is a #{entry['visibility']} #{kind} of #{unit['type']} unit " \
          "#{unit['identifier']}, not a unit of its own. Look up #{unit['identifier']} for the whole unit."
      end

      # @param reference [Reference]
      # @param unit [Hash] the owner's published unit
      # @return [String] the sentence a not-found answer adds when the owner exists
      def missing_sentence(reference, unit)
        sentence = "#{unit['identifier']} (#{unit['type']}) is a published unit, but #{reference.name} " \
                   "(#{reference.kind_label}) was not found in its published source."
        return sentence unless given_class_method?(unit, reference)

        "#{sentence} #{reference.name} is defined in its `class_methods do` block: a class method " \
          "#{unit['identifier']} gives to the classes that include it, not a method of #{unit['identifier']} " \
          "itself. Look it up as a class method of a class that includes #{unit['identifier']}."
      end

      # Whether +reference+ names a class method the unit's own
      # `class_methods do` block defines (one it gives to its includers).
      def given_class_method?(unit, reference)
        return false unless reference.separator == '.'

        lines = ConcernClassMethods.own_lines(unit['source_code'], unit['identifier'])
        methods_of(unit).any? do |entry|
          entry['name'] == reference.name && !entry['file_unit'] && lines.include?(entry['line'])
        end
      end

      # The definition Ruby would call, and the others of the same name.
      # The unit's own definitions win over an inlined concern's, and the
      # later of two definitions in one body wins.
      #
      # @return [Array(Hash, Array<Hash>), nil]
      def locate(unit, reference)
        class_method_lines = nil
        own_class_methods = nil
        matches = methods_of(unit).select do |entry|
          next false unless entry['name'] == reference.name && member_owner?(entry, unit['identifier'])

          unless entry['file_unit']
            own_class_methods ||= ConcernClassMethods.own_lines(unit['source_code'], unit['identifier'])
            next reference.kind?(entry) && !own_class_methods.include?(entry['line'])
          end

          class_method_lines ||= ConcernClassMethods.lines(unit['source_code'])
          reference.concern_kind?(entry, class_method_lines)
        end
        return nil if matches.empty?

        ordered = matches.map { |entry| reference.as_named(entry) }
                         .sort_by { |entry| [entry['file_unit'] ? 0 : 1, entry['line'].to_i] }
        [ordered.last, ordered[0...-1].reverse]
      end

      # An entry of the unit's own class body, or of an inlined concern's own
      # module body. A nested class's method is not a member of the unit.
      def member_owner?(entry, identifier)
        entry['owner'] == (entry['file_unit'] || identifier)
      end

      # @return [Array<Hash>] the published method table, or one read from the
      #   published source when the unit predates it
      def methods_of(unit)
        metadata = unit['metadata'].is_a?(Hash) ? unit['metadata'] : {}
        published = metadata['methods']
        return published.grep(Hash) if published.is_a?(Array)

        source = unit['source_code']
        table = MethodTable.call(source)
        return [] unless table

        locator = FileLines::Locator.new(source, metadata['source_line_map'])
        table.map { |entry| locator.annotate(entry) }
      end

      # The lines of the definitions a concern makes inside its
      # `class_methods do` block: for an inlined concern ({.lines}), class
      # methods of the including unit; for a concern unit's own body
      # ({.own_lines}), class methods it gives to its includers and does not
      # respond to itself. Read by a Prism walk of each decoded block
      # ({Woods::MethodTable.named_blocks}). Only a definition written
      # directly in that block (or as `private def`) counts; a block that does
      # not parse contributes nothing, so its singletons are not members.
      # `module ClassMethods` is not read: its methods are not answered.
      module ConcernClassMethods
        VISIBILITY = %i[private protected public].freeze

        module_function

        # @param source [String, nil] the unit's published source
        # @return [Set<Integer>] published-source lines of those definitions
        def lines(source)
          return Set.new unless source.is_a?(String)

          MethodTable.named_blocks(source.lines(chomp: true)).each_with_object(Set.new) do |(first, text, name), found|
            parsed = Woods::ParseCache.parse(text)
            next if parsed.errors.any?

            definitions(parsed.value.statements, nil, name).each { |line| found << (line + first - 1) }
          end
        end

        # The lines of the definitions a concern unit's own `class_methods do`
        # block makes: class methods of its includers, not of the concern.
        #
        # @param source [String, nil] the unit's published source
        # @param identifier [String] the unit's identifier
        # @return [Set<Integer>] published-source lines of those definitions
        def own_lines(source, identifier)
          return Set.new unless source.is_a?(String)

          parsed = Woods::ParseCache.parse(source)
          return Set.new if parsed.errors.any?

          definitions(parsed.value.statements, nil, identifier).to_set
        end

        # Start lines of the `class_methods` definitions in the body of the
        # module named +concern+.
        def definitions(node, owner, concern)
          statements(node).flat_map do |statement|
            next [] unless statement.is_a?(Prism::ModuleNode) || statement.is_a?(Prism::ClassNode)

            inner = MethodTable::Names.qualified(owner, statement.constant_path)
            next [] unless inner

            inner == concern ? class_methods_in(statement.body) : definitions(statement.body, inner, concern)
          end
        end

        def class_methods_in(body)
          statements(body).flat_map do |statement|
            next [] unless class_methods_call?(statement)

            statements(statement.block.body).flat_map { |inner| definition_lines(inner) }
          end
        end

        def class_methods_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :class_methods &&
            node.block.is_a?(Prism::BlockNode)
        end

        def definition_lines(node)
          case node
          when Prism::DefNode then node.receiver ? [] : [node.location.start_line]
          when Prism::CallNode
            return [] unless node.receiver.nil? && VISIBILITY.include?(node.name)

            node.arguments&.arguments.to_a.flat_map { |argument| definition_lines(argument) }
          else []
          end
        end

        def statements(node)
          case node
          when Prism::StatementsNode then node.body
          when nil then []
          else [node]
          end
        end
      end

      # The definition's lines of the published source; a definition inside
      # an inlined concern block is decoded from its comment frame.
      def source_text(source, entry)
        first = entry['line']
        last = entry['end_line']
        return nil unless source.is_a?(String) && first.is_a?(Integer) && last.is_a?(Integer)

        lines = source.lines[(first - 1)..(last - 1)] || []
        lines = lines.map { |line| "#{line.chomp[MethodTable::BLOCK_LINE, 1]}\n" } if entry['file_unit']
        lines.join
      end
    end
  end
end
