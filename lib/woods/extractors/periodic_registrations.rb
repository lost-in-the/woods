# frozen_string_literal: true

require 'prism'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Reads Sidekiq Enterprise periodic registrations from Ruby source without
    # running it. `configure_server` blocks only execute inside a Sidekiq
    # server process, so the registrations are invisible to a booted rake task.
    #
    # A registration is `<param>.register(cron, job_class, options)` where
    # `<param>` is the block parameter of a `periodic` block.
    #
    # @example
    #   PeriodicRegistrations.read("config.periodic { |m| m.register('0 * * * *', 'SweepWorker') }")
    #   # => [{ cron: '0 * * * *', job_class: 'SweepWorker', options: {}, line: 1 }]
    module PeriodicRegistrations
      # Raised when the source does not parse.
      class ParseError < StandardError; end

      module_function

      # @param source [String] Ruby source
      # @return [Array<Hash>] registrations in source order; `:job_class` is nil
      #   when the class argument is not a literal constant name
      # @raise [ParseError] when Prism reports a syntax error
      def read(source)
        result = Prism.parse(source)
        raise ParseError, result.errors.first.message unless result.success?

        calls = []
        collect_periodic_blocks(result.value, calls)
        calls.map { |call| registration(call) }
      end

      def collect_periodic_blocks(node, calls)
        if periodic_block?(node)
          name = block_parameter(node.block)
          collect_registrations(node.block.body, name, calls) if name
          return
        end

        node.compact_child_nodes.each { |child| collect_periodic_blocks(child, calls) }
      end

      def collect_registrations(node, receiver_name, calls)
        return unless node

        calls << node if registration_call?(node, receiver_name)
        node.compact_child_nodes.each { |child| collect_registrations(child, receiver_name, calls) }
      end

      def periodic_block?(node)
        node.is_a?(Prism::CallNode) && node.name == :periodic && node.block.is_a?(Prism::BlockNode)
      end

      def block_parameter(block)
        parameters = block.parameters
        return unless parameters.is_a?(Prism::BlockParametersNode)

        first = parameters.parameters&.requireds&.first
        first.name if first.is_a?(Prism::RequiredParameterNode)
      end

      def registration_call?(node, receiver_name)
        node.is_a?(Prism::CallNode) && node.name == :register &&
          node.receiver.is_a?(Prism::LocalVariableReadNode) && node.receiver.name == receiver_name
      end

      def registration(call)
        cron, job_class, options = call.arguments&.arguments || []
        {
          cron: cron.is_a?(Prism::StringNode) ? cron.unescaped : nil,
          job_class: class_name(job_class),
          options: literal_hash(options),
          line: call.location.start_line
        }
      end

      def class_name(node)
        name = case node
               when Prism::StringNode then node.unescaped
               when Prism::ConstantReadNode, Prism::ConstantPathNode then node.slice
               end
        name.delete_prefix('::') if name&.match?(SourceReferences::RuntimeLookup::CONSTANT)
      end

      def literal_hash(node)
        return {} unless node.is_a?(Prism::KeywordHashNode) || node.is_a?(Prism::HashNode)

        node.elements.each_with_object({}) do |element, hash|
          next unless element.is_a?(Prism::AssocNode)

          hash[literal(element.key).to_s] = literal(element.value)
        end
      end

      # Literal values become Ruby values; anything computed keeps its source.
      def literal(node)
        case node
        when Prism::StringNode, Prism::SymbolNode then node.unescaped
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        else node.slice
        end
      end

      private_class_method :collect_periodic_blocks, :collect_registrations, :periodic_block?,
                           :block_parameter, :registration_call?, :registration, :class_name,
                           :literal_hash, :literal
    end
  end
end
