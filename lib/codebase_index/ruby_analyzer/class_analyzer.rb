# frozen_string_literal: true

require_relative '../ast/parser'
require_relative '../extracted_unit'
require_relative 'fqn_builder'

module CodebaseIndex
  module RubyAnalyzer
    # Extracts class and module definitions from Ruby source code using the AST layer.
    #
    # Produces ExtractedUnit objects with type :ruby_class or :ruby_module, including
    # metadata about superclass, includes, extends, constants, and method count.
    #
    # @example
    #   analyzer = RubyAnalyzer::ClassAnalyzer.new
    #   units = analyzer.analyze(source: File.read(path), file_path: path)
    #   units.first.type #=> :ruby_class
    #
    class ClassAnalyzer
      include FqnBuilder

      # @param parser [Ast::Parser, nil] Parser instance (creates default if nil)
      def initialize(parser: nil)
        @parser = parser || Ast::Parser.new
      end

      # Analyze source code and extract class/module units.
      #
      # @param source [String] Ruby source code
      # @param file_path [String] Absolute path to the source file
      # @return [Array<ExtractedUnit>] Extracted class and module units
      def analyze(source:, file_path:)
        root = @parser.parse(source)
        units = []
        extract_definitions(root, source, file_path, [], units)
        units
      end

      private

      def extract_definitions(node, source, file_path, namespace_stack, units)
        return unless node.is_a?(Ast::Node)

        case node.type
        when :class
          process_class(node, source, file_path, namespace_stack, units)
        when :module
          process_module(node, source, file_path, namespace_stack, units)
        else
          (node.children || []).each do |child|
            extract_definitions(child, source, file_path, namespace_stack, units)
          end
        end
      end

      def process_class(node, source, file_path, namespace_stack, units)
        process_definition(node, :ruby_class, source, file_path, namespace_stack, units)
      end

      def process_module(node, source, file_path, namespace_stack, units)
        process_definition(node, :ruby_module, source, file_path, namespace_stack, units)
      end

      def process_definition(node, type, source, file_path, namespace_stack, units)
        name = node.method_name
        fqn = build_fqn(name, namespace_stack)
        namespace = build_namespace(name, namespace_stack)

        superclass = type == :ruby_class ? extract_superclass(node) : nil
        children = body_children(node, type)
        includes = extract_mixins(children, 'include')
        extends = extract_mixins(children, 'extend')
        constants = extract_constants(children)
        method_count = count_methods(children)

        unit = ExtractedUnit.new(type: type, identifier: fqn, file_path: file_path)
        unit.namespace = namespace
        unit.source_code = extract_source(node, source)
        unit.metadata = {
          superclass: superclass,
          includes: includes,
          extends: extends,
          constants: constants,
          method_count: method_count
        }
        unit.dependencies = build_dependencies(superclass, includes, extends)
        units << unit

        # Recurse into body for nested definitions
        inner_ns = namespace_stack + fqn_parts(name)
        children.each do |child|
          extract_definitions(child, source, file_path, inner_ns, units)
        end
      end

      # Build namespace string (everything except the leaf name).
      def build_namespace(name, namespace_stack)
        parts = namespace_stack + fqn_parts(name)
        parts.pop # Remove leaf
        parts.empty? ? nil : parts.join('::')
      end

      # Split a name that may contain :: into parts.
      def fqn_parts(name)
        name.to_s.split('::')
      end

      # Extract superclass name from a class node.
      # Children[0] is name, children[1] is superclass (or nil).
      def extract_superclass(class_node)
        superclass_node = class_node.children[1]
        return nil unless superclass_node.is_a?(Ast::Node) && superclass_node.type == :const

        build_const_name(superclass_node)
      end

      # Get body children of a class or module node.
      # Class: children[0] = name, children[1] = superclass, rest = body
      # Module: children[0] = name, rest = body
      def body_children(node, type)
        offset = type == :ruby_class ? 2 : 1
        (node.children || [])[offset..] || []
      end

      # Extract include/extend module names from body send nodes.
      def extract_mixins(body_children, method_name)
        body_children.filter_map do |child|
          next unless child.is_a?(Ast::Node) && child.type == :send
          next unless child.method_name == method_name
          next if child.arguments.nil? || child.arguments.empty?

          child.arguments.first
        end
      end

      # Extract constant assignment names from body.
      def extract_constants(body_children)
        body_children.filter_map do |child|
          next unless child.is_a?(Ast::Node) && child.type == :casgn

          child.method_name
        end
      end

      # Count def and defs nodes in body children (non-recursive — only direct methods).
      def count_methods(body_children)
        count = 0
        body_children.each do |child|
          next unless child.is_a?(Ast::Node)

          count += 1 if %i[def defs].include?(child.type)
        end
        count
      end

      # Build the constant name from a :const node (may have receiver for namespaced).
      def build_const_name(const_node)
        parts = []
        parts << const_node.receiver if const_node.receiver
        parts << const_node.method_name if const_node.method_name
        parts.join('::')
      end

      # Extract source text for a node using line range.
      def extract_source(node, source)
        return nil unless node.line && node.end_line

        lines = source.lines
        start_idx = node.line - 1
        end_idx = node.end_line - 1
        return nil if start_idx < 0 || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end

      # Build dependency list from superclass, includes, and extends.
      def build_dependencies(superclass, includes, extends)
        deps = []
        deps << { type: :ruby_class, target: superclass, via: :inheritance } if superclass
        includes.each do |mod|
          deps << { type: :ruby_class, target: mod, via: :include }
        end
        extends.each do |mod|
          deps << { type: :ruby_class, target: mod, via: :extend }
        end
        deps
      end
    end
  end
end
