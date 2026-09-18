# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Reads only the selected declaration's explicit constant-path parent.
    # Identity selection remains with the extractor; literals and unrelated
    # declarations must never supply metadata for that identity.
    module DeclaredParent
      module_function

      def call(source, identifier)
        parsed = Prism.parse(source)
        return nil unless parsed.success?

        find(parsed.value, identifier, '')&.first
      end

      def find(node, identifier, namespace)
        return unless node

        if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          name = constant_name(node.constant_path)
          return unless name

          qualified = name.start_with?('::') ? name.delete_prefix('::') : [namespace, name].reject(&:empty?).join('::')
          if qualified == identifier
            return [node.is_a?(Prism::ClassNode) ? constant_name(node.superclass) : nil]
          end

          return find(node.body, identifier, qualified)
        end

        node.compact_child_nodes.each do |child|
          match = find(child, identifier, namespace)
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
