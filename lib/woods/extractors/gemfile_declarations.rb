# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Reads literal Bundler declarations without evaluating the Gemfile. Dynamic
    # names are omitted, and dynamic version requirements remain unknown.
    class GemfileDeclarations
      # @param source [String] redacted Gemfile source
      # @return [Array<Hash>] name, requirement, groups and source kind (path/git/nil)
      def self.call(source)
        new.call(source)
      end

      # @param source [String] redacted Gemfile source
      # @return [Array<Hash>] declarations in source order
      def call(source)
        @gems = []
        visit(Prism.parse(source).value, groups: [], source: nil)
        @gems
      end

      private

      def visit(node, groups:, source:)
        return unless node

        bare_call = node.is_a?(Prism::CallNode) && node.receiver.nil?
        record(node, groups, source) if bare_call && node.name == :gem
        block_groups, block_source = bare_call ? block_context(node, groups, source) : [groups, source]
        node.compact_child_nodes.each do |child|
          scoped = bare_call && child.equal?(node.block)
          visit(child, groups: scoped ? block_groups : groups, source: scoped ? block_source : source)
        end
      end

      def arguments(node)
        node.arguments&.arguments || []
      end

      def block_context(node, groups, source)
        case node.name
        when :group then [(groups + arguments(node).flat_map { |arg| literals(arg) }).uniq, source]
        when :path, :git then [groups, node.name.to_s]
        when :source then [groups, nil]
        else [groups, source]
        end
      end

      def record(node, groups, source)
        args = arguments(node)
        name = string_value(args.first)
        return unless name

        options = options_for(args)
        selected_groups = (groups + literals(options[:group]) + literals(options[:groups])).uniq
        @gems << { name: name, requirement: requirement(args),
                   groups: selected_groups.empty? ? ['default'] : selected_groups,
                   source: source_kind(options, source) }
      end

      def options_for(args)
        options = args.find { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
        return {} unless options

        options.elements.each_with_object({}) do |entry, result|
          next unless entry.is_a?(Prism::AssocNode)

          key = string_value(entry.key) || (entry.key.unescaped if entry.key.is_a?(Prism::SymbolNode))
          result[key.to_sym] = entry.value if key
        end
      end

      def source_kind(options, inherited)
        return 'path' if options.key?(:path)
        return 'git' if options.key?(:git)
        return nil if options.key?(:source)

        inherited
      end

      def requirement(args)
        versions = args.drop(1).reject { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
        values = versions.map { |arg| string_value(arg) }
        return nil if values.empty? || values.any?(&:nil?)

        values.join(', ')
      end

      def literals(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then [node.unescaped]
        when Prism::ArrayNode then node.elements.flat_map { |element| literals(element) }
        else []
        end
      end

      def string_value(node)
        node.unescaped if node.is_a?(Prism::StringNode)
      end
    end
  end
end
