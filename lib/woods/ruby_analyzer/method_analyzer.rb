# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../ast/method_extractor'
require_relative '../ast/call_site_extractor'
require_relative '../extracted_unit'
require_relative '../method_table'
require_relative '../parse_cache'

module Woods
  module RubyAnalyzer
    # Extracts method-level units from Ruby source code.
    #
    # The methods, their owners, sides and visibility come from the source's
    # method table ({Woods::MethodTable::Walker}), so a unit exists for each
    # method Ruby defines while it evaluates the class and module bodies:
    # `private def x`, `memoize def x`, `private :x` after the definition,
    # both sides of a `module_function`. A definition Ruby runs only on one
    # path (under a conditional, or in a block of the body) is a unit marked
    # +metadata[:candidate]+ with the table's reason. Each unit's call graph
    # is read from the definition's node in the normalized AST.
    #
    # @example
    #   analyzer = RubyAnalyzer::MethodAnalyzer.new
    #   units = analyzer.analyze(source: File.read(path), file_path: path)
    #   units.first.identifier #=> "MyClass#my_method"
    #
    class MethodAnalyzer
      # Receivers kept in a call graph: a constant, relative or absolute.
      CONSTANT_RECEIVER = /\A(?:::)?[A-Z]/

      # @param parser [Ast::Parser, nil] Parser instance (creates default if nil)
      def initialize(parser: nil)
        @parser = parser || Ast::Parser.new
        @call_site_extractor = Ast::CallSiteExtractor.new
      end

      # Analyze source code and extract method units.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] Absolute path to the source file
      # @return [Array<ExtractedUnit>] Extracted method units, in source order
      # @raise [Woods::ExtractionError] if the source does not parse
      def analyze(source:, file_path:)
        nodes = definition_nodes(@parser.parse(source))
        shared = shared_lines(nodes.values)
        entries = MethodTable::Walker.new(offsets: true).call(Woods::ParseCache.parse(source).value)
        entries.sort_by { |entry| entry.values_at(MethodTable::Marks::OFFSET, 'kind') }.flat_map do |entry|
          node = nodes[entry[MethodTable::Marks::OFFSET]]
          text = node && definition_source(node, source, shared)
          sides(entry).map do |separator, visibility|
            build_method_unit(entry, separator, visibility, node, text, file_path)
          end
        end
      end

      private

      # Each definition node of the normalized tree by the byte offset where
      # its `def` starts: two definitions can share a line and a name (`def
      # a; end; def self.a; end`), never a starting position.
      def definition_nodes(root)
        (root.find_all(:def) + root.find_all(:defs)).to_h { |node| [node.start_byte, node] }
      end

      # Lines on which more than one definition starts or ends.
      def shared_lines(nodes)
        nodes.flat_map { |node| [node.line, node.end_line].uniq }.tally.filter_map { |line, count| line if count > 1 }
      end

      # A definition's whole lines, or exactly its own text when another
      # definition starts or ends on one of those lines.
      def definition_source(node, source, shared)
        return node.source unless shared.include?(node.line) || shared.include?(node.end_line)

        source.byteslice(node.start_byte, node.end_byte - node.start_byte)
      end

      # The methods a table entry stands for: a module function is a private
      # instance method and a singleton copy with the entry's visibility.
      #
      # @return [Array<Array(String, String)>] separator and visibility
      def sides(entry)
        case entry['kind']
        when 'instance' then [['#', entry['visibility']]]
        when 'singleton' then [['.', entry['visibility']]]
        else [['#', 'private'], ['.', entry['visibility']]]
        end
      end

      def build_method_unit(entry, separator, visibility, method_node, text, file_path)
        owner = entry['owner']
        call_graph = method_node ? extract_call_graph(method_node) : []
        unit = ExtractedUnit.new(type: :ruby_method, identifier: "#{owner}#{separator}#{entry['name']}",
                                 file_path: file_path)
        unit.namespace = owner
        unit.source_code = text
        unit.metadata = { visibility: visibility.to_sym, call_graph: call_graph }
        unit.metadata[:candidate] = entry[MethodTable::CANDIDATE] if entry[MethodTable::CANDIDATE]
        unit.dependencies = build_dependencies(call_graph)
        unit
      end

      def extract_call_graph(method_node)
        calls = @call_site_extractor.extract(method_node)
        calls.filter_map do |call|
          next unless call[:receiver]&.match?(CONSTANT_RECEIVER)

          {
            target: call[:receiver],
            method: call[:method_name],
            line: call[:line]
          }
        end
      end

      def build_dependencies(call_graph)
        call_graph.map { |c| c[:target] }.uniq.map do |target|
          { type: :ruby_class, target: target, via: :method_call }
        end
      end
    end
  end
end
