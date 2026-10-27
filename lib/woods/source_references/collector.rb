# frozen_string_literal: true

require_relative 'prism_adapter'
require_relative 'parser_adapter'
require_relative 'selector'
require_relative 'macros'

module Woods
  module SourceReferences
    # Collects source constant reads without resolving or executing Ruby objects.
    # Owners are declaration candidates, not proof of runtime ownership. In
    # particular, a nested qualified declaration must be verified by the registry.
    # Lexical nesting is innermost first and preserves compact namespace syntax.
    # References/declarations inside class << self carry singleton_depth; resolving
    # them requires the singleton constant table, not ordinary owner lookup.
    class Collector # rubocop:disable Metrics/ClassLength -- one visitor owns declaration, reference and call-site handling
      HANDLERS = { declaration: :declaration, value_class: :value_class, constant: :reference,
                   singleton: :singleton, method: :method_body, call: :call_site }.freeze
      include Macros

      # @param backend [Symbol] :prism (default) or :parser
      # @raise [ArgumentError] for an unsupported backend
      def initialize(backend: :prism)
        @adapter = case backend
                   when :prism then PrismAdapter.new
                   when :parser then ParserAdapter.new
                   else raise ArgumentError, "Unsupported source reference backend: #{backend}"
                   end
      end

      # Parse original source and return JSON-compatible candidate evidence.
      # Parse failures return no partial records. Unsupported ownership has an
      # explicit skip reason; declaration ranges are inclusive source lines.
      #
      # @param source [String] original Ruby source
      # @return [Hash] declarations, references, skipped records and parse_error
      def call(source)
        @mixins = {}.compare_by_identity
        @result = { 'declarations' => [], 'references' => [], 'skipped' => [], 'macros' => [], 'parse_error' => nil }
        root, error = @adapter.parse(source)
        @result['parse_error'] = error
        visit(root, []) unless error
        @result
      end

      private

      def visit(node, nesting, singleton_depth = 0)
        return unless node

        kind = @adapter.kind(node)
        return skip(node, 'dynamic_declaration', nesting) if kind == :dynamic_scope

        handler = HANDLERS[kind]
        handler ? send(handler, node, nesting, singleton_depth) : visit_children(node, nesting, singleton_depth)
      end

      def visit_children(node, nesting, singleton_depth)
        @adapter.children(node).each { |child| visit(child, nesting, singleton_depth) }
      end

      def declaration(node, nesting, singleton_depth)
        name = @adapter.declaration_name(node)
        return skip(node, 'dynamic_declaration', nesting) unless name

        owner = name.start_with?('::') ? name.delete_prefix('::') : [nesting.first, name].compact.join('::')
        inner = [owner, *nesting]
        record = declaration_record(node, name, inner, nesting)
        record['singleton_depth'] = singleton_depth if singleton_depth.positive?
        @result['declarations'] << record
        parent = @adapter.superclass(node)
        skip(parent, 'dynamic_superclass', inner) if parent && !@adapter.constant_name(parent)
        visit(@adapter.body(node), inner, singleton_depth)
      end

      def value_class(node, nesting, singleton_depth)
        name = @adapter.assignment_name(node)
        return skip(node, 'dynamic_declaration', nesting) unless name

        owner = name.start_with?('::') ? name.delete_prefix('::') : [nesting.first, name].compact.join('::')
        record = { 'owner' => owner, 'name' => name, 'kind' => 'class',
                   'constructor' => @adapter.value_constructor(node), 'nesting' => [owner, *nesting],
                   'enclosing_nesting' => nesting,
                   'line' => @adapter.line(node), 'end_line' => @adapter.end_line(node) }
        record['singleton_depth'] = singleton_depth if singleton_depth.positive?
        @result['declarations'] << record
        # Struct/Data blocks execute with a dynamic receiver; assignment does not
        # establish lexical nesting. Keep their bodies explicitly unsupported.
        visit_children(node, nesting, singleton_depth)
      end

      def declaration_record(node, name, nesting, enclosing)
        { 'owner' => nesting.first, 'name' => name, 'kind' => @adapter.declaration_kind(node),
          'nesting' => nesting, 'enclosing_nesting' => enclosing,
          'line' => @adapter.line(node), 'end_line' => @adapter.end_line(node) }
      end

      def reference(node, nesting, singleton_depth, selector = nil)
        mixin = @mixins.delete(node)
        name = @adapter.constant_name(node)
        return skip(node, 'dynamic_constant_path', nesting) unless name
        return skip(node, 'unowned_reference', nesting) if nesting.empty?

        record = { 'owner' => nesting.first, 'nesting' => nesting, 'name' => name, **@adapter.position(node) }
        record['singleton_depth'] = singleton_depth if singleton_depth.positive?
        record['method'] = selector if selector
        record['mixin'] = mixin if mixin
        @result['references'] << record
      end

      def call_site(node, nesting, singleton_depth)
        macro(node, nesting) if singleton_depth.zero? && nesting.any?
        mark_mixins(node)
        receiver = @adapter.constant_receiver(node)
        return visit_children(node, nesting, singleton_depth) unless receiver

        @adapter.children(node).each do |child|
          if child.equal?(@adapter.receiver(node))
            reference(receiver, nesting, singleton_depth, Selector.from(@adapter.selector(node)))
          else
            visit(child, nesting, singleton_depth)
          end
        end
      end

      # Receiverless class-body macros: each literal symbol argument (the first
      # only for associations and scopes) with its source position.
      def macro(node, nesting)
        return unless @adapter.receiver(node).nil?

        name = @adapter.selector(node).to_s
        return unless MACROS.include?(name)

        symbols = @adapter.leading_symbols(node)
        symbols = symbols.first(1) unless CALLBACK_MACROS.include?(name)
        symbols.each do |symbol, position|
          @result['macros'] << { 'owner' => nesting.first, 'macro' => name, 'name' => symbol, **position }
        end
      end

      def singleton(node, nesting, singleton_depth)
        return skip(node, 'dynamic_singleton_scope', nesting) unless @adapter.self_receiver?(node) && nesting.any?

        visit(@adapter.body(node), nesting, singleton_depth + 1)
      end

      def method_body(node, nesting, singleton_depth)
        return skip(node, 'dynamic_method_owner', nesting) unless @adapter.local_method?(node)

        visit_children(node, nesting, singleton_depth)
      end

      def skip(node, reason, nesting)
        @result['skipped'] << { 'reason' => reason, 'owner' => nesting.first, 'line' => @adapter.line(node) }
      end
    end
  end
end
