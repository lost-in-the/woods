# frozen_string_literal: true

require_relative 'parser'
require_relative 'node'

module Woods
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
      include SourceSpan

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
        extract_source_span(source, node.line, node.end_line)
      end

      # Extract the raw source text of every instance-method definition,
      # keyed by method name — one parse answers every query (P1).
      #
      # A name defined more than once keeps its first definition, matching
      # {#extract_method_source}'s first-match lookup, so
      # `extract_method_sources(source)[name]` is byte-identical to
      # `extract_method_source(source, name)` for every name. A caller that
      # knows which definition Ruby dispatches selects it through
      # {#extract_method_definitions} instead.
      #
      # @param source [String] Ruby source code
      # @return [Hash{String => String}] method name => source text
      def extract_method_sources(source)
        extract_method_definitions(source).each_with_object({}) do |((name, _line), text), map|
          map[name] ||= text
        end
      end

      # Every `def` in the file keyed by `[name, line]`, in tree order, so a
      # name defined more than once (a redefinition, two classes in one file,
      # a `class << self` def beside an instance method of the same name) can
      # be selected by the line Ruby's `source_location` reports (F5).
      #
      # @param source [String] Ruby source code
      # @return [Hash{Array(String, Integer) => String}] [name, line] => source text
      def extract_method_definitions(source)
        root = @parser.parse(source)
        root.find_all(:def).to_h do |node|
          [[node.method_name, node.line], node.source || extract_source_span(source, node.line, node.end_line)]
        end
      end
    end
  end
end
