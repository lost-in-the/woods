# frozen_string_literal: true

require_relative 'prism_adapter'
require_relative 'parser_adapter'

module Woods
  module SourceReferences
    # Collects source constant reads without resolving or executing Ruby objects.
    # Owners are declaration candidates, not proof of runtime ownership. In
    # particular, a nested qualified declaration must be verified by the registry.
    # Lexical nesting is innermost first and preserves compact namespace syntax.
    # References/declarations inside class << self carry singleton_depth; resolving
    # them requires the singleton constant table, not ordinary owner lookup.
    class Collector
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
        @result = { 'declarations' => [], 'references' => [], 'skipped' => [], 'parse_error' => nil }
        root, error = @adapter.parse(source)
        @result['parse_error'] = error
        visit(root, []) unless error
        @result
      end

      private

      def visit(node, nesting, singleton_depth = 0)
        return unless node

        case @adapter.kind(node)
        when :declaration then declaration(node, nesting, singleton_depth)
        when :constant then reference(node, nesting, singleton_depth)
        when :singleton then singleton(node, nesting, singleton_depth)
        when :method then method_body(node, nesting, singleton_depth)
        when :dynamic_scope then skip(node, 'dynamic_declaration', nesting)
        else visit_children(node, nesting, singleton_depth)
        end
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

      def declaration_record(node, name, nesting, enclosing)
        { 'owner' => nesting.first, 'name' => name, 'kind' => @adapter.declaration_kind(node),
          'nesting' => nesting, 'enclosing_nesting' => enclosing,
          'line' => @adapter.line(node), 'end_line' => @adapter.end_line(node) }
      end

      def reference(node, nesting, singleton_depth)
        name = @adapter.constant_name(node)
        return skip(node, 'dynamic_constant_path', nesting) unless name
        return skip(node, 'unowned_reference', nesting) if nesting.empty?

        record = { 'owner' => nesting.first, 'nesting' => nesting, 'name' => name, 'line' => @adapter.line(node) }
        record['singleton_depth'] = singleton_depth if singleton_depth.positive?
        @result['references'] << record
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
