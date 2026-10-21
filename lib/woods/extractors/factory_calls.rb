# frozen_string_literal: true

require 'prism'

module Woods
  module Extractors
    # Reads `factory` calls from a factory file's syntax tree.
    #
    # A factory's options are an argument list, not a line: they wrap onto
    # continuation lines, use `class:` or `:class =>`, and combine in any
    # order. Reading them from the parsed call gets every form, and never
    # mistakes a `factory :name` inside a string or comment for a definition.
    #
    # @example
    #   FactoryCalls.by_line("factory :refund,\n  parent: :entry do\nend\n")
    #   # => { 1 => { name: "refund", explicit_class: nil, parent_factory: "entry",
    #   #            aliases: [], block_line: 2 } }
    #
    module FactoryCalls
      CONSTANT_PATH = /\A(?:::)?[A-Z]\w*(?:::[A-Z]\w*)*\z/

      module_function

      # @param source [String] factory file source
      # @return [Hash{Integer => Hash}, nil] call facts keyed by the 1-based
      #   line the call starts on, or nil when the source does not parse
      def by_line(source)
        parsed = Prism.parse(source)
        return nil unless parsed.success?

        calls = {}
        collect(parsed.value, calls)
        calls
      end

      def collect(node, calls)
        return unless node

        if factory_call?(node)
          facts = facts_for(node)
          calls[node.location.start_line] ||= facts if facts
        end
        node.compact_child_nodes.each { |child| collect(child, calls) }
      end

      def factory_call?(node)
        node.is_a?(Prism::CallNode) && node.name == :factory && node.receiver.nil? && node.arguments
      end

      def facts_for(node)
        name, *rest = node.arguments.arguments
        name = literal(name)
        return nil unless name

        options = option_pairs(rest)
        {
          name: name,
          explicit_class: class_name(options['class']),
          parent_factory: literal(options['parent']),
          aliases: alias_names(options['aliases']),
          block_line: do_block_line(node.block)
        }
      end

      # Only a `do` block has an `end` for the parser's depth count to meet.
      def do_block_line(block)
        block.location.start_line if block.is_a?(Prism::BlockNode) && block.opening == 'do'
      end

      # @return [Hash{String => Prism::Node}] option name => value node
      def option_pairs(arguments)
        hashes = arguments.select { |arg| arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::HashNode) }
        hashes.flat_map(&:elements).each_with_object({}) do |element, pairs|
          next unless element.is_a?(Prism::AssocNode)

          key = literal(element.key)
          pairs[key] ||= element.value if key
        end
      end

      # @return [String, nil] the value of a symbol or plain string literal
      def literal(node)
        node.unescaped if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      # `class: Ledger::Entry`, `class: "::Ledger::Entry"`, `class: :ledger_entry`.
      def class_name(node)
        case node
        when Prism::SymbolNode then node.unescaped.split('_').map(&:capitalize).join
        when Prism::StringNode then constant(node.unescaped)
        when Prism::ConstantReadNode, Prism::ConstantPathNode then constant(node.slice)
        end
      end

      def constant(text)
        text.delete_prefix('::') if text.match?(CONSTANT_PATH)
      end

      def alias_names(node)
        return [] unless node.is_a?(Prism::ArrayNode)

        node.elements.filter_map { |element| literal(element) }
      end
    end
  end
end
