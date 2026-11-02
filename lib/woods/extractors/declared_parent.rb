# frozen_string_literal: true

require 'prism'
require_relative '../parse_cache'

module Woods
  module Extractors
    # Reads only the selected declaration's explicit constant-path parent.
    # Identity selection remains with the extractor; literals and unrelated
    # declarations must never supply metadata for that identity.
    module DeclaredParent
      module_function

      def call(source, identifier)
        declaration(source, identifier)&.fetch(:parent)
      end

      # The selected class declaration's parent spelling and the lexical
      # scopes its parent expression is evaluated in, innermost first: the
      # qualified names of the enclosing class and module blocks, as
      # `Module.nesting` reads just outside the class keyword.
      #
      # @param source [String] Ruby source
      # @param identifier [String] the fully qualified class the file declares
      # @return [Hash, nil] `{ parent: String, nesting: Array<String> }` for a
      #   class with an explicit constant parent; nil otherwise
      def declaration(source, identifier)
        parsed = Woods::ParseCache.parse(source)
        return nil unless parsed.success?

        match = find(parsed.value, identifier, '', [])
        match if match&.fetch(:parent)
      end

      def find(node, identifier, namespace, scopes)
        return unless node

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          name = constant_name(node.constant_path)
          return unless name

          qualified = name.start_with?('::') ? name.delete_prefix('::') : [namespace, name].reject(&:empty?).join('::')
          if qualified == identifier
            parent = node.is_a?(Prism::ClassNode) ? constant_name(node.superclass) : nil
            return { parent: parent, nesting: scopes }
          end

          return find(node.body, identifier, qualified, [qualified, *scopes])
        end

        node.compact_child_nodes.each do |child|
          match = find(child, identifier, namespace, scopes)
          return match if match
        end
        nil
      end
      private_class_method :find

      def constant_name(node)
        case node
        when Prism::ConstantReadNode
          node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? constant_name(node.parent) : ''
          "#{parent}::#{node.name}" if parent
        end
      end
      private_class_method :constant_name
    end
  end
end
