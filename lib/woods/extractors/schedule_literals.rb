# frozen_string_literal: true

require 'prism'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Prism helpers shared by the readers of schedules registered in Ruby
    # config sources ({PeriodicRegistrations}, {SidekiqCronRegistrations},
    # {SidekiqSchedulerRegistrations}). Nothing here runs the source.
    module ScheduleLiterals
      # Raised when the source does not parse.
      class ParseError < StandardError; end

      # Keys that name the job class in a schedule hash.
      CLASS_KEYS = %w[class klass].freeze

      module_function

      # @param source [String] Ruby source
      # @return [Prism::ProgramNode]
      # @raise [ParseError] when Prism reports a syntax error
      def parse(source)
        result = Prism.parse(source)
        raise ParseError, result.errors.first.message unless result.success?

        result.value
      end

      # Yield every node under `node`, depth first, in source order.
      #
      # @param node [Prism::Node, nil]
      # @yieldparam node [Prism::Node]
      # @return [void]
      def each_node(node, &block)
        return unless node

        yield node
        node.compact_child_nodes.each { |child| each_node(child, &block) }
      end

      # @param node [Prism::Node, nil] a class argument
      # @return [String, nil] the constant name when the node is a literal one
      def class_name(node)
        name = case node
               when Prism::StringNode then node.unescaped
               when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
               end
        name.delete_prefix('::') if name&.match?(SourceReferences::RuntimeLookup::CONSTANT)
      end

      # @param node [Prism::Node, nil]
      # @return [Boolean] true for a `{ ... }` or bare keyword hash
      def hash_node?(node)
        node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
      end

      # Literal values become Ruby values; anything computed keeps its source.
      #
      # @param node [Prism::Node, nil]
      # @return [Object]
      def literal(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode, nil then nil
        when Prism::ArrayNode then node.elements.map { |element| literal(element) }
        when Prism::HashNode, Prism::KeywordHashNode then literal_hash(node)
        else node.slice
        end
      end

      # @param node [Prism::Node, nil]
      # @return [Hash{String => Object}] string keys; empty unless the node is a hash
      def literal_hash(node)
        assocs(node).to_h { |key, value| [literal(key).to_s, literal(value)] }
      end

      # @param node [Prism::Node, nil]
      # @return [Array<Array(Prism::Node, Prism::Node)>] key/value node pairs
      def assocs(node)
        return [] unless hash_node?(node)

        node.elements.grep(Prism::AssocNode).map { |element| [element.key, element.value] }
      end

      # Read one schedule definition hash (`name:`, `cron:`, `class:`, ...).
      #
      # @param node [Prism::Node] the hash
      # @param name_node [Prism::Node, nil] the name when it is the hash's key elsewhere
      # @return [Hash] `:name`, `:job_class`, `:cron` (nil when not literal, with the
      #   source under `:name_source`, `:job_class_source`, `:cron_source`) and the
      #   remaining keys as `:options`
      def entry(node, name_node: nil)
        values = assocs(node).to_h { |key, value| [literal(key).to_s, value] }
        name_node ||= values.delete('name')
        class_node = CLASS_KEYS.filter_map { |key| values.delete(key) }.first
        cron_node = values.delete('cron')
        {
          **literal_or_source(:name, name_node) { |n| literal_text(n) },
          **literal_or_source(:job_class, class_node) { |n| class_name(n) },
          **literal_or_source(:cron, cron_node) { |n| n.unescaped if n.is_a?(Prism::StringNode) },
          options: values.transform_values { |value| literal(value) }
        }
      end

      def literal_text(node)
        node.unescaped if node.is_a?(Prism::StringNode) || node.is_a?(Prism::SymbolNode)
      end

      def literal_or_source(key, node)
        value = node && yield(node)
        result = { key => value }
        result[:"#{key}_source"] = node.slice if node && value.nil?
        result
      end

      private_class_method :literal_text, :literal_or_source
    end
  end
end
