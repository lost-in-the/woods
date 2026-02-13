# frozen_string_literal: true

require_relative 'parser'
require_relative 'node'

module CodebaseIndex
  module Ast
    # Extracts method definitions and their source from Ruby source code.
    #
    # Replaces the fragile ~240 lines of `nesting_delta` / `neutralize_strings_and_comments`
    # / `detect_heredoc_start` indentation heuristics in controller and mailer extractors.
    #
    # @example Extracting a method's source
    #   extractor = Ast::MethodExtractor.new
    #   source = extractor.extract_method_source(code, "create")
    #   # => "def create\n  @user = User.find(params[:id])\nend\n"
    #
    class MethodExtractor
      # @param parser [Ast::Parser, nil] Parser instance (creates default if nil)
      def initialize(parser: nil)
        @parser = parser || Parser.new
      end

      # Extract a method definition node by name.
      #
      # @param source [String] Ruby source code
      # @param method_name [String] Method name to find
      # @param class_method [Boolean] If true, look for `def self.method_name`
      # @return [Ast::Node, nil] The :def or :defs node, or nil if not found
      def extract_method(source, method_name, class_method: false)
        root = @parser.parse(source)
        target_type = class_method ? :defs : :def

        root.find_all(target_type).find do |node|
          node.method_name == method_name.to_s
        end
      end

      # Extract all method definition nodes from source.
      #
      # @param source [String] Ruby source code
      # @return [Array<Ast::Node>] All :def and :defs nodes
      def extract_all_methods(source)
        root = @parser.parse(source)
        root.find_all(:def) + root.find_all(:defs)
      end

      # Extract the raw source text of a method, including def...end.
      #
      # This is the key replacement for `extract_action_source` in the controller
      # and mailer extractors. Uses AST line tracking instead of indentation heuristics.
      #
      # @param source [String] Ruby source code
      # @param method_name [String] Method name to find
      # @param class_method [Boolean] If true, look for `def self.method_name`
      # @return [String, nil] The method source text, or nil if not found
      def extract_method_source(source, method_name, class_method: false)
        node = extract_method(source, method_name, class_method: class_method)
        return nil unless node

        # If the node has a source field populated by the parser, use it
        return node.source if node.source

        # Fallback: extract by line range
        return nil unless node.line && node.end_line

        lines = source.lines
        start_idx = node.line - 1
        end_idx = node.end_line - 1
        return nil if start_idx < 0 || end_idx >= lines.length

        lines[start_idx..end_idx].join
      end
    end
  end
end
