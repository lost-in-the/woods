# frozen_string_literal: true

require_relative 'node'

module CodebaseIndex
  module Ast
    # Resolves constant paths from AST nodes to fully qualified names.
    #
    # Given a set of known constants (e.g., from extracted units), resolves
    # partial constant references to their full paths using namespace context.
    #
    # @example Resolving constants
    #   resolver = Ast::ConstantResolver.new(known_constants: ["CodebaseIndex::Extractor", "CodebaseIndex::ExtractedUnit"])
    #   resolver.resolve(node, namespace: "CodebaseIndex") #=> "CodebaseIndex::Extractor"
    #
    class ConstantResolver
      # @param known_constants [Array<String>] List of fully qualified constant names
      def initialize(known_constants: [])
        @known_constants = known_constants.to_set
      end

      # Resolve a single constant node to a fully qualified name.
      #
      # @param node [Ast::Node] A :const node
      # @param namespace [String, nil] Current namespace context
      # @return [String, nil] Fully qualified name, or nil if unknown
      def resolve(node, namespace: nil)
        return nil unless node.is_a?(Ast::Node) && node.type == :const

        raw_name = build_const_name(node)
        return nil unless raw_name

        # If it starts with ::, it's absolute
        if raw_name.start_with?('::')
          fqn = raw_name.delete_prefix('::')
          return fqn if @known_constants.include?(fqn) || @known_constants.empty?

          return nil
        end

        # Try exact match first
        return raw_name if @known_constants.include?(raw_name) || @known_constants.empty?

        # Try with namespace context
        if namespace
          candidates = build_namespace_candidates(raw_name, namespace)
          candidates.each do |candidate|
            return candidate if @known_constants.include?(candidate)
          end
        end

        # Return raw name if no known constants to match against
        return raw_name if @known_constants.empty?

        nil
      end

      # Resolve all constant references in a tree.
      #
      # @param root [Ast::Node] Root node to search
      # @param namespace [String, nil] Current namespace context
      # @return [Array<Hash>] Each hash has :name, :fqn, :line keys
      def resolve_all(root, namespace: nil)
        const_nodes = root.find_all(:const)
        const_nodes.filter_map do |node|
          raw_name = build_const_name(node)
          next unless raw_name

          fqn = resolve(node, namespace: namespace)
          { name: raw_name, fqn: fqn, line: node.line }
        end.uniq { |h| [h[:name], h[:line]] }
      end

      private

      def build_const_name(node)
        return nil unless node.is_a?(Ast::Node) && node.type == :const

        parts = []
        parts << node.receiver if node.receiver
        parts << node.method_name if node.method_name
        parts.join('::')
      end

      def build_namespace_candidates(name, namespace)
        parts = namespace.split('::')
        candidates = []

        # Try progressively shorter namespace prefixes
        # e.g., for name="Extractor" and namespace="CodebaseIndex::Ast"
        # try: CodebaseIndex::Ast::Extractor, CodebaseIndex::Extractor
        parts.length.downto(1) do |i|
          prefix = parts[0...i].join('::')
          candidates << "#{prefix}::#{name}"
        end

        candidates
      end
    end
  end
end
