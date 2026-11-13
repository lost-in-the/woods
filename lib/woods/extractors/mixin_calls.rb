# frozen_string_literal: true

require 'prism'
require_relative '../parse_cache'

module Woods
  module Extractors
    # The mixins a Ruby source declares: each `include`, `extend` or
    # `prepend` call and each constant written as its argument, read from the
    # Prism tree. Only a real call declares a mixin; a comment, string,
    # heredoc or method name that contains the word does not, and neither
    # does an argument that is not a constant (`extend self`). The receiver
    # is not checked, so `base.extend ClassMethods` inside `self.included`
    # counts, as it did when this was a text scan.
    module MixinCalls
      KINDS = %i[include extend prepend].freeze
      HELPER_NAME = /\A\w+Helper\z/

      module_function

      # @param source [String] Ruby source
      # @param kinds [Array<Symbol>] which of {KINDS} to read
      # @return [Array<Array(Symbol, String)>] the call and the constant as
      #   written (a leading `::` kept), in source order
      def call(source, kinds = KINDS)
        return [] unless source.is_a?(String) && !source.empty?

        found = []
        visitor = Visitor.new(kinds, found)
        Woods::ParseCache.parse(source).value.accept(visitor)
        found
      end

      # The `*Helper` modules a source includes by bare name, as the helper
      # scans of component and mailer extractors have always read them.
      #
      # @param source [String] Ruby source
      # @return [Array<String>] distinct names in source order
      def helper_includes(source)
        call(source, %i[include]).map(&:last).grep(HELPER_NAME).uniq
      end

      # Collects the constant arguments of the chosen calls.
      class Visitor < Prism::Visitor
        CONSTANTS = [Prism::ConstantReadNode, Prism::ConstantPathNode].freeze

        def initialize(kinds, found)
          super()
          @kinds = kinds
          @found = found
        end

        # @param node [Prism::CallNode]
        def visit_call_node(node)
          if @kinds.include?(node.name)
            node.arguments&.arguments.to_a.each do |argument|
              next unless CONSTANTS.any? { |type| argument.is_a?(type) }

              @found << [node.name, argument.slice.gsub(/\s+/, '')]
            end
          end
          super
        end
      end
    end
  end
end
