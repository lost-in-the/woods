# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Syntactic method signatures only: never evaluate a default expression or
    # mistake names inside one for additional parameters. Consumers retain their
    # existing metadata shapes by selecting the fields they expose.
    module MethodParameters
      module_function

      def extract(source, method_name)
        parsed = Prism.parse(source)
        return [] unless parsed.success?

        method = find_method(parsed.value, method_name.to_sym)
        return [] unless method&.parameters

        method.parameters.compact_child_nodes.flat_map { |node| describe(node) }
      end

      def find_method(node, name)
        return nil if node.is_a?(Prism::SingletonClassNode)
        return node if node.is_a?(Prism::DefNode) && node.receiver.nil? && node.name == name

        node.compact_child_nodes.each do |child|
          found = find_method(child, name)
          return found if found
        end
        nil
      end

      def describe(node)
        # Destructured positional arguments contain declarations, while a
        # default's subtree contains values and must never be walked.
        return node.compact_child_nodes.flat_map { |child| describe(child) } if node.is_a?(Prism::MultiTargetNode)
        return [] unless node.respond_to?(:name) && node.name

        optional = node.is_a?(Prism::OptionalParameterNode) || node.is_a?(Prism::OptionalKeywordParameterNode)
        keyword = node.is_a?(Prism::RequiredKeywordParameterNode) ||
                  node.is_a?(Prism::OptionalKeywordParameterNode) || node.is_a?(Prism::KeywordRestParameterNode)
        splat = if node.is_a?(Prism::KeywordRestParameterNode)
                  :double
                elsif node.is_a?(Prism::RestParameterNode)
                  :single
                end
        [{ name: node.name.to_s, has_default: optional, keyword: keyword, splat: splat }]
      end
      private_class_method :find_method, :describe
    end
  end
end
