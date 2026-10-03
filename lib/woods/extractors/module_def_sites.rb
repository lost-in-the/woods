# frozen_string_literal: true

require 'prism'
require 'set'

module Woods
  module Extractors
    # Method names a file's own module bodies declare with `def`.
    #
    # Runtime reflection reports where a method object was created, which is
    # another file when a wrapper helper redefines it. The `def` site is the
    # evidence that this module body still declares the method. Nested class
    # and module bodies belong to their own declarations and are not read.
    class ModuleDefSites
      # @param source [String] Ruby source of one file
      def initialize(source)
        @tree = Prism.parse(source).value
      end

      # @param lines [Enumerable<Integer>] start lines of the module declarations to read
      # @return [Set<String>] method names declared with `def` in those bodies
      def call(lines)
        lines = lines.to_set
        names = Set.new
        each_module(@tree) do |node|
          collect(node.body, names) if lines.include?(node.location.start_line)
        end
        names
      end

      private

      def each_module(node, &block)
        return unless node

        yield node if node.is_a?(Prism::ModuleNode)
        node.compact_child_nodes.each { |child| each_module(child, &block) }
      end

      def collect(node, names)
        case node
        when nil, Prism::ClassNode, Prism::ModuleNode then nil
        when Prism::DefNode then names << node.name.to_s
        else node.compact_child_nodes.each { |child| collect(child, names) }
        end
      end
    end
  end
end
