# frozen_string_literal: true

require_relative '../method_table'
require_relative '../file_lines'

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
        "#{unit['identifier']} (#{unit['type']}) is a published unit, but #{reference.name} " \
          "(#{reference.kind_label}) was not found in its published source."
      end

      # The definition Ruby would call, and the others of the same name.
      # The unit's own definitions win over an inlined concern's, and the
      # later of two definitions in one body wins.
      #
      # @return [Array(Hash, Array<Hash>), nil]
      def locate(unit, reference)
        matches = methods_of(unit).select do |entry|
          entry['name'] == reference.name && reference.kind?(entry) && member_owner?(entry, unit['identifier'])
        end
        return nil if matches.empty?

        ordered = matches.sort_by { |entry| [entry['file_unit'] ? 0 : 1, entry['line'].to_i] }
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
