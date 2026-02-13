# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../ast/method_extractor'
require_relative '../ast/call_site_extractor'
require_relative '../extracted_unit'

module CodebaseIndex
  module RubyAnalyzer
    # Extracts method-level units from Ruby source code.
    #
    # For each class/module, extracts methods as ExtractedUnit objects with type
    # :ruby_method. Includes visibility, parameters, call graph, and dependencies.
    #
    # @example
    #   analyzer = RubyAnalyzer::MethodAnalyzer.new
    #   units = analyzer.analyze(source: File.read(path), file_path: path)
    #   units.first.identifier #=> "MyClass#my_method"
    #
    class MethodAnalyzer
      # @param parser [Ast::Parser, nil] Parser instance (creates default if nil)
      def initialize(parser: nil)
        @parser = parser || Ast::Parser.new
        @call_site_extractor = Ast::CallSiteExtractor.new
      end

      # Analyze source code and extract method units.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] Absolute path to the source file
      # @return [Array<ExtractedUnit>] Extracted method units
      def analyze(source:, file_path:)
        root = @parser.parse(source)
        units = []
        extract_methods_from_tree(root, source, file_path, [], units)
        units
      end

      private

      def extract_methods_from_tree(node, source, file_path, namespace_stack, units)
        return unless node.is_a?(Ast::Node)

        case node.type
        when :class
          process_class_methods(node, source, file_path, namespace_stack, units)
        when :module
          process_module_methods(node, source, file_path, namespace_stack, units)
        else
          (node.children || []).each do |child|
            extract_methods_from_tree(child, source, file_path, namespace_stack, units)
          end
        end
      end

      def process_class_methods(node, source, file_path, namespace_stack, units)
        class_name = node.method_name
        fqn = build_fqn(class_name, namespace_stack)
        body_children = (node.children || [])[2..] || []

        visibility_tracker = VisibilityTracker.new
        inner_ns = namespace_stack + [class_name]

        body_children.each do |child|
          next unless child.is_a?(Ast::Node)

          case child.type
          when :send
            visibility_tracker.process_send(child)
          when :def
            units << build_method_unit(child, fqn, '#', visibility_tracker.current, file_path)
          when :defs
            units << build_method_unit(child, fqn, '.', :public, file_path)
          when :class, :module
            extract_methods_from_tree(child, source, file_path, inner_ns, units)
          end
        end
      end

      def process_module_methods(node, source, file_path, namespace_stack, units)
        mod_name = node.method_name
        fqn = build_fqn(mod_name, namespace_stack)
        body_children = (node.children || [])[1..] || []

        visibility_tracker = VisibilityTracker.new
        inner_ns = namespace_stack + [mod_name]

        body_children.each do |child|
          next unless child.is_a?(Ast::Node)

          case child.type
          when :send
            visibility_tracker.process_send(child)
          when :def
            units << build_method_unit(child, fqn, '#', visibility_tracker.current, file_path)
          when :defs
            units << build_method_unit(child, fqn, '.', :public, file_path)
          when :class, :module
            extract_methods_from_tree(child, source, file_path, inner_ns, units)
          end
        end
      end

      def build_method_unit(method_node, class_fqn, separator, visibility, file_path)
        identifier = "#{class_fqn}#{separator}#{method_node.method_name}"
        call_graph = extract_call_graph(method_node)
        dependencies = build_dependencies(call_graph)
        parameters = extract_parameters(method_node)

        unit = ExtractedUnit.new(type: :ruby_method, identifier: identifier, file_path: file_path)
        unit.namespace = class_fqn
        unit.source_code = method_node.source || extract_source_from_lines(method_node)
        unit.metadata = {
          visibility: visibility,
          parameters: parameters,
          call_graph: call_graph
        }
        unit.dependencies = dependencies
        unit
      end

      def extract_call_graph(method_node)
        calls = @call_site_extractor.extract(method_node)
        calls.filter_map do |call|
          next unless call[:receiver]
          # Only include calls with a capitalized receiver (likely a class/constant)
          next unless call[:receiver].match?(/\A[A-Z]/)

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

      def extract_parameters(method_node)
        # Parameters aren't directly in our normalized AST, return empty for now.
        # The node source contains the full signature if needed.
        []
      end

      def extract_source_from_lines(node)
        node.source
      end

      def build_fqn(name, namespace_stack)
        if namespace_stack.empty?
          name
        else
          "#{namespace_stack.join('::')}::#{name}"
        end
      end

      # Tracks visibility state as we walk through class body statements.
      class VisibilityTracker
        VISIBILITY_METHODS = %w[private protected public].freeze

        attr_reader :current

        def initialize
          @current = :public
        end

        # Process a send node that might be a visibility modifier.
        def process_send(send_node)
          return unless send_node.method_name
          return unless VISIBILITY_METHODS.include?(send_node.method_name)
          # Only bare calls (no receiver, no arguments) act as section modifiers
          return if send_node.receiver
          return if send_node.arguments && !send_node.arguments.empty?

          @current = send_node.method_name.to_sym
        end
      end
    end
  end
end
