# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # The groups and examples of a test file, in the unit's published
    # `source_code` coordinates (#870): name, label, 1-based line extent and the
    # `focus`/`skip`/`pending` markers written on them.
    #
    # One Prism walk of the file reads the RSpec DSL (`describe`, `context`,
    # `it`, `specify`, `scenario`, shared groups and their inclusion) and the
    # Minitest forms (`class FooTest`, `test "..."`, `def test_...`). Nothing is
    # executed, so a name is published only where the source states it:
    #
    # - A string, symbol or constant argument is static.
    # - Anything else (interpolation, a variable, a call, no argument) leaves
    #   the name `nil` and sets `dynamic`. The text is never guessed.
    # - A static example created inside an iteration block (`%w[a b].each { ... }`)
    #   is marked `generated`: the file does not say how many it makes.
    #
    # Absence of `examples` means the table is unavailable (source that does not
    # parse); an empty array means the file states no group or example.
    module TestExamples
      # Calls that open an example group.
      GROUPS = %w[describe context feature example_group].freeze
      # Calls that define one example.
      EXAMPLES = %w[it specify example scenario its].freeze
      # `skip "name" do` and `pending "name" do` define a marked example.
      MARKED_EXAMPLES = { 'skip' => :skip, 'pending' => :pending }.freeze
      # `x` skips and `f` focuses: `xit`, `fdescribe`.
      PREFIX_MARKS = { 'x' => :skip, 'f' => :focus }.freeze
      SHARED_GROUPS = %w[shared_examples shared_examples_for shared_context].freeze
      INCLUDES = %w[it_behaves_like it_should_behave_like include_examples include_context].freeze
      MARKERS = %i[focus skip pending].freeze
      # A description part that attaches to a described module without a space.
      JOINED = /\A(?:#|::|\.)/

      # A written description: +text+ is nil when it is not static.
      Label = Struct.new(:text, :module_part)
      private_constant :Label

      # What encloses a node: the labels of its groups and what they inherit.
      Context = Struct.new(:parts, :marks, :shared, :generated) do
        def chain
          parts.map(&:text)
        end

        def nested(label, marks: self.marks, shared: self.shared)
          Context.new(parts + [label], marks, shared, generated)
        end

        def generated!
          Context.new(parts, marks, shared, true)
        end
      end
      private_constant :Context

      module_function

      # Record the table on a test unit about to be written.
      #
      # @param unit [ExtractedUnit]
      # @return [void]
      def record(unit)
        return unless unit.type.to_s == 'test_mapping'

        table = call(unit.source_code, framework: unit.metadata[:test_framework])
        if table
          unit.metadata[:examples] = table
        else
          unit.metadata.delete(:examples)
        end
      end

      # @param source [String, nil] the test file as published
      # @param framework [Symbol, String, nil] +:minitest+ also reads classes,
      #   `test "..."` and `def test_...`
      # @return [Array<Hash>, nil] string-keyed entries in source order, or nil
      #   when the source is absent or does not parse
      def call(source, framework: nil)
        return nil unless source.is_a?(String)

        result = Prism.parse(source)
        return nil if result.errors.any?

        Walker.new(minitest: framework.to_s == 'minitest').call(result.value)
      end

      # One walk of a parsed tree.
      class Walker
        def initialize(minitest:)
          @minitest = minitest
          @entries = []
        end

        # @param root [Prism::Node]
        # @return [Array<Hash>]
        def call(root)
          visit(root, Context.new([], {}, false, false))
          @entries
        end

        private

        def visit(node, context)
          case node
          when Prism::CallNode then visit_call(node, context)
          when Prism::ClassNode then visit_class(node, context)
          when Prism::DefNode then visit_def(node, context)
          when nil then nil
          else node.compact_child_nodes.each { |child| visit(child, context) }
          end
        end

        def visit_call(node, context)
          name = node.name.to_s
          return visit_other(node, context) unless dsl_receiver?(node)

          if group_name?(name) && block?(node) then group(node, context, name)
          elsif example_name?(name) && (block?(node) || (arguments?(node) && !MARKED_EXAMPLES.key?(name)))
            example(node, context, name)
          elsif SHARED_GROUPS.include?(name) && block?(node) then shared_group(node, context)
          elsif INCLUDES.include?(name) && arguments?(node) then inclusion(node, context, name)
          elsif @minitest && name == 'test' && node.receiver.nil? && block?(node) then minitest_test(node, context)
          else visit_other(node, context)
          end
        end

        # A call outside the DSL. Its block runs at load time, so an example
        # defined inside is generated by code rather than written once.
        def visit_other(node, context)
          inside = node.block ? context.generated! : context
          node.compact_child_nodes.each { |child| visit(child, child.is_a?(Prism::BlockNode) ? inside : context) }
        end

        def dsl_receiver?(node)
          receiver = node.receiver
          receiver.nil? || (receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :RSpec)
        end

        def block?(node)
          node.block.is_a?(Prism::BlockNode)
        end

        def arguments?(node)
          !node.arguments.nil?
        end

        def group_name?(name)
          GROUPS.include?(name) || !prefix_mark(name, GROUPS).nil?
        end

        def example_name?(name)
          EXAMPLES.include?(name) || MARKED_EXAMPLES.key?(name) || !prefix_mark(name, EXAMPLES).nil?
        end

        # @return [Symbol, nil] the marker a `x`/`f` prefixed name carries
        def prefix_mark(name, bases)
          return nil if bases.include?(name) || !PREFIX_MARKS.key?(name[0])

          PREFIX_MARKS[name[0]] if bases.include?(name[1..])
        end

        # ── Constructs ───────────────────────────────────────────────────

        def group(node, context, name)
          label = describe(node)
          marks = marks_for(node, context, prefix_mark(name, GROUPS))
          add('group', node, context, label, marks)
          visit_block(node, context.nested(label, marks: marks))
        end

        def example(node, context, name)
          label = describe(node)
          marks = marks_for(node, context, MARKED_EXAMPLES[name] || prefix_mark(name, EXAMPLES))
          marks = marks.merge(pending: true) unless block?(node) || marks.key?(:skip)
          add('example', node, context, label, marks)
        end

        def shared_group(node, context)
          label = describe(node)
          add('shared_group', node, context, label, context.marks, shared: true)
          visit_block(node, context.nested(label, shared: true))
        end

        def inclusion(node, context, name)
          entry = add('include', node, context, describe(node), context.marks)
          entry['via'] = name
          visit_block(node, context)
        end

        def minitest_test(node, context)
          add('example', node, context, describe(node), context.marks)
        end

        def visit_def(node, context)
          return unless @minitest && node.receiver.nil? && node.name.to_s.start_with?('test_')

          add('example', node, context, Label.new(node.name.to_s, false), context.marks)
        end

        # A Minitest class is a group only when it holds an example.
        def visit_class(node, context)
          return node.compact_child_nodes.each { |child| visit(child, context) } unless @minitest

          label = Label.new(node.constant_path.slice, true)
          index = @entries.size
          entry = entry_for('group', node, context, label, context.marks)
          visit(node.body, context.nested(label))
          @entries.insert(index, entry) if @entries.size > index
        end

        def visit_block(node, context)
          body = node.block
          visit(body.body, context) if body.is_a?(Prism::BlockNode)
        end

        # ── Entries ──────────────────────────────────────────────────────

        def add(kind, node, context, label, marks, shared: false)
          entry = entry_for(kind, node, context, label, marks, shared: shared)
          @entries << entry
          entry
        end

        def entry_for(kind, node, context, label, marks, shared: false)
          location = node.location
          entry = { 'kind' => kind, 'name' => label.text, 'chain' => context.chain,
                    'line' => location.start_line, 'end_line' => location.end_line }
          text = full_label(context, label) unless kind == 'include' || shared || context.shared
          entry['label'] = text if text
          entry['dynamic'] = true if label.text.nil? || context.chain.any?(&:nil?)
          entry['generated'] = true if context.generated
          entry['shared'] = true if shared || context.shared
          MARKERS.each { |marker| entry[marker.to_s] = true if marks[marker] }
          entry
        end

        # RSpec's full description: the parts joined with a space, except that
        # `#name`, `::Name` and `.name` attach to a described module.
        def full_label(context, label)
          parts = context.parts + [label]
          return nil if parts.any? { |part| part.text.nil? }

          text = nil
          module_part = false
          parts.each do |part|
            if text.nil? || text.empty?
              text = part.text
              module_part = part.module_part
            else
              separator = module_part && part.text.match?(JOINED) ? '' : ' '
              text = "#{text}#{separator}#{part.text}"
              module_part = false
            end
          end
          text
        end

        # ── Arguments ────────────────────────────────────────────────────

        # The description a call states. A symbol after the first argument is
        # metadata, not description.
        def describe(node)
          arguments = node.arguments&.arguments.to_a
          positional = arguments.grep_v(Prism::KeywordHashNode)
          parts = positional.each_with_index.filter_map do |argument, index|
            next unless description?(argument, index)

            literal(argument)
          end
          counted = positional.each_with_index.count { |argument, index| description?(argument, index) }
          return Label.new(nil, false) if parts.empty? || parts.size != counted || parts.any?(&:nil?)

          Label.new(parts.join(' '), parts.size == 1 && constant?(positional.first))
        end

        def description?(argument, index)
          !(index.positive? && argument.is_a?(Prism::SymbolNode))
        end

        def constant?(node)
          node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
        end

        # @return [String, nil] the argument's text when the source states it
        def literal(node)
          case node
          when Prism::StringNode, Prism::SymbolNode then node.unescaped
          when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
          when Prism::InterpolatedStringNode then joined_strings(node)
          end
        end

        # Adjacent literals (`"a" "b"`) parse as one interpolated string of
        # plain parts; a real interpolation is not static.
        def joined_strings(node)
          return nil unless node.parts.all?(Prism::StringNode)

          node.parts.map(&:unescaped).join
        end

        # ── Markers ──────────────────────────────────────────────────────

        # The markers written on the call, on top of those its groups carry.
        def marks_for(node, context, prefix_mark)
          written = context.marks.dup
          written[prefix_mark] = true if prefix_mark
          arguments = node.arguments&.arguments.to_a
          arguments.each_with_index do |argument, index|
            case argument
            when Prism::SymbolNode
              marker = argument.unescaped.to_sym
              written[marker] = true if index.positive? && MARKERS.include?(marker)
            when Prism::KeywordHashNode then keyword_marks(argument, written)
            end
          end
          written
        end

        def keyword_marks(hash, written)
          hash.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

            marker = element.key.unescaped.to_sym
            next unless MARKERS.include?(marker)

            falsy = element.value.is_a?(Prism::FalseNode) || element.value.is_a?(Prism::NilNode)
            falsy ? written.delete(marker) : written[marker] = true
          end
        end
      end
    end
  end
end
