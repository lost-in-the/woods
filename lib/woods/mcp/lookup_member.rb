# frozen_string_literal: true

require_relative '../method_table'
require_relative '../file_lines'
require_relative '../parse_cache'
require_relative 'lookup_member_resolution'
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

      # The member answer for +reference+ in +unit+: the definition Ruby
      # calls, read through the published superclass chain
      # ({Resolution}), or every candidate with a statement that the index
      # cannot tell which one Ruby calls.
      #
      # @param unit [Hash] the owner's published unit
      # @param reference [Reference]
      # @param concern_file [#call, nil] concern name => its file path, or nil
      # @param find_unit [#call, nil] (identifier, type) => a published unit,
      #   to read the superclass chain; nil reads the owner's unit alone
      # @return [Hash, nil] string-keyed answer, or nil when neither the
      #   unit's published source nor its superclass chain holds such a method
      def answer(unit, reference, concern_file: nil, find_unit: nil)
        resolution = Resolution.new(unit, reference, find_unit: find_unit).call
        return nil unless resolution

        owner = { 'identifier' => unit['identifier'], 'type' => unit['type'], 'file_path' => unit['file_path'] }
        result = { 'identifier' => reference.identifier, 'member_of' => owner }
        possible = resolution.chosen&.origin == :possible_macro
        if resolution.ambiguous
          result['statement'] = ambiguous_statement(reference, unit, resolution)
          result['candidates'] = resolution.ambiguous.map do |candidate|
            definition(candidate, resolution, concern_file)
          end
        elsif possible
          result['statement'] = statement(reference, unit, resolution)
          result['candidates'] = possible_macro_candidates(reference, resolution, concern_file)
        else
          shown = definition(resolution.chosen, resolution, concern_file)
          result['member'] = shown.delete('member')
          result['statement'] = statement(reference, unit, resolution)
          result.merge!(shown.except('source_code'))
        end
        unless possible
          others = resolution.overridden.map { |candidate| located(candidate, resolution) }
          result['other_definitions'] = others unless others.empty?
        end
        result['caveats'] = resolution.caveats unless resolution.caveats.empty?
        result['source_code'] = shown['source_code'] if shown
        result
      end

      # The answer without source text (`include_source: false`).
      #
      # @param answer [Hash] a {.answer}
      # @return [Hash]
      def without_source(answer)
        result = answer.except('source_code')
        return result unless result['candidates']

        result.merge('candidates' => result['candidates'].map { |candidate| candidate.except('source_code') })
      end

      # One definition: its method table entry, where it comes from and its
      # source text.
      def definition(candidate, resolution, concern_file)
        result = { 'member' => located(candidate, resolution) }
        ancestor = resolution.chain[candidate.level]
        if candidate.concern
          result['defined_in'] = { 'identifier' => candidate.concern,
                                   'file_path' => concern_file&.call(candidate.concern) }
          result['defined_in']['prepended'] = true if candidate.origin == :prepended
          result['defined_in']['included_by'] = ancestor['identifier'] unless candidate.level.zero?
        elsif !candidate.level.zero?
          result['inherited_from'] = { 'identifier' => ancestor['identifier'], 'type' => ancestor['type'],
                                       'file_path' => ancestor['file_path'] }
        end
        result['source_code'] = source_text(candidate.unit['source_code'], candidate.entry)
        result
      end

      # The candidate's entry; `unit` names the published unit whose source
      # its `line`/`end_line` count in when that is not the asked owner's.
      def located(candidate, resolution)
        return candidate.entry if candidate.unit.equal?(resolution.chain.first)

        candidate.entry.merge('unit' => candidate.unit['identifier'])
      end

      # @return [String] the sentence that says what the answer is and how it
      #   was established
      def statement(reference, unit, resolution)
        chosen = resolution.chosen
        return macro_statement(reference, unit, resolution) if %i[macro possible_macro].include?(chosen.origin)

        entry = chosen.entry
        head = "#{reference.identifier} is a #{entry['visibility']} " \
               "#{KIND_LABELS.fetch(entry['kind'], reference.kind_label)}"
        "#{head}#{origin_clause(unit, chosen, resolution.chain[chosen.level])}" \
          "#{overrides(reference, resolution)} #{not_a_unit(unit)}"
      end

      # How the chosen definition reaches the owner.
      def origin_clause(unit, chosen, ancestor)
        owner = "#{unit['type']} unit #{unit['identifier']}"
        inherited = !chosen.level.zero?
        case chosen.origin
        when :own
          return " of #{owner}, defined in its own body." unless inherited

          " that #{owner} inherits from #{ancestor['type']} unit #{ancestor['identifier']}, defined in its own body."
        when :prepended
          by = inherited ? "its superclass #{ancestor['identifier']}" : unit['identifier']
          " of #{owner}, from module #{chosen.concern}, which #{by} prepends."
        else
          through = inherited ? ", which it gets through its superclass #{ancestor['identifier']}" : ''
          " of #{owner}, inlined from concern #{chosen.concern}#{through}."
        end
      end

      # The statement of an answer from a class-body call: the level whose
      # own body makes it, and whether Woods knows that it defines the name.
      def macro_statement(reference, unit, resolution)
        chosen = resolution.chosen
        entry = chosen.entry
        level = resolution.chain[chosen.level]
        owner = "#{unit['type']} unit #{unit['identifier']}"
        call = "`#{entry['defined_by']}` (line #{entry['line']} of its published source)"
        if chosen.origin == :possible_macro
          where = chosen.level.zero? ? owner : "#{level['type']} unit #{level['identifier']}, a superclass of #{owner},"
          return "#{reference.identifier}: #{where} calls #{call} in its own body with #{reference.name} as an " \
                 "argument, so it may define the #{reference.kind_label} #{reference.name} there. Woods does not " \
                 "know what `#{entry['defined_by']}` does, so it cannot tell which definition Ruby calls. " \
                 'Each definition is listed under candidates, the call first; if it does not define ' \
                 "#{reference.name}, Ruby calls the next one. #{not_a_unit(unit)}"
        end
        how = "defined in its own body by #{call}#{", as an alias of #{entry['alias_of']}" if entry['alias_of']}"
        label = KIND_LABELS.fetch(entry['kind'], reference.kind_label)
        kind = entry['visibility'] ? "#{entry['visibility']} #{label}" : label
        head = "#{reference.identifier} is #{kind.match?(/\A[aeiou]/) ? 'an' : 'a'} #{kind}"
        origin = if chosen.level.zero?
                   " of #{owner}, #{how}."
                 else
                   " that #{owner} inherits from #{level['type']} unit #{level['identifier']}, #{how}."
                 end
        "#{head}#{origin}#{overrides(reference, resolution)} #{not_a_unit(unit)}"
      end

      # The candidates of an answer from a call Woods does not know: the
      # call, then every definition past it, nearest first; each call Woods
      # does not know carries a note that it may define the name.
      def possible_macro_candidates(reference, resolution, concern_file)
        [resolution.chosen, *resolution.overridden].map do |candidate|
          shown = definition(candidate, resolution, concern_file)
          next shown unless candidate.origin == :possible_macro

          shown.merge('note' => "may define #{reference.name}: Woods does not know what " \
                                "`#{candidate.entry['defined_by']}` does")
        end
      end

      # @return [String] the statement of an answer the index cannot rank
      def ambiguous_statement(reference, unit, resolution)
        concerns = resolution.ambiguous.map(&:concern)
        "#{reference.identifier}: #{concerns.size} concerns inlined into #{unit['type']} unit " \
          "#{unit['identifier']} define the #{reference.kind_label} #{reference.name} " \
          "(#{concerns.join(', ')}), and the index does not record the order in which they were included, " \
          'so Woods cannot tell which one Ruby calls. Each definition is listed under candidates.' \
          "#{overrides(reference, resolution, 'They override')} #{not_a_unit(unit)}"
      end

      def overrides(reference, resolution, subject = 'It overrides')
        count = resolution.overridden.size
        return '' if count.zero?

        " #{subject} #{count} other definition#{'s' unless count == 1} of #{reference.name}."
      end

      def not_a_unit(unit)
        "It is not a unit of its own; look up #{unit['identifier']} for the whole unit."
      end

      # @param reference [Reference]
      # @param unit [Hash] the owner's published unit
      # @param find_unit [#call, nil] as for {.answer}, to read the superclass
      #   chain for a call that names the member
      # @return [String] the sentence a not-found answer adds when the owner exists
      def missing_sentence(reference, unit, find_unit: nil)
        sentence = "#{unit['identifier']} (#{unit['type']}) is a published unit, but #{reference.name} " \
                   "(#{reference.kind_label}) was not found in its published source."
        if given_class_method?(unit, reference)
          sentence = "#{sentence} #{reference.name} is defined in its `class_methods do` block: a class method " \
                     "#{unit['identifier']} gives to the classes that include it, not a method of " \
                     "#{unit['identifier']} itself. Look it up as a class method of a class that includes " \
                     "#{unit['identifier']}."
        end
        hint = macro_hint(reference, unit, find_unit)
        hint ? "#{sentence} #{hint}" : sentence
      end

      # A call Woods does not know that names the member, where nothing else
      # on that side defines it.
      def macro_hint(reference, unit, find_unit)
        resolution = Resolution.new(unit, reference, find_unit: find_unit)
        return nil if resolution.call

        site = resolution.unresolved_macro
        site && "`#{site.entry['defined_by']}` at line #{site.entry['line']} of the published source of " \
                "#{site.unit['identifier']} names it and may define it."
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
