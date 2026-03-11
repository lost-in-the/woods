# frozen_string_literal: true

require 'set'
require_relative 'node'

module CodebaseIndex
  module Ast
    # Method names that are too common to be useful in call graphs.
    INSIGNIFICANT_METHODS = Set.new(%w[
                                      to_s to_i to_f to_a to_h to_sym to_r to_c to_str to_proc
                                      nil? present? blank? empty? any? none? frozen? is_a? kind_of?
                                      respond_to? respond_to_missing? instance_of? equal?
                                      == != eql? <=> === =~ !~ >= <= > <
                                      ! & | ^ ~ + - * / % **
                                      freeze dup clone inspect hash object_id class
                                      send __send__ method tap then yield_self itself
                                      new allocate
                                      [] []=
                                      length size count
                                      first last
                                      map each select reject flat_map collect detect find_index
                                      merge merge! update
                                      keys values
                                      push pop shift unshift
                                      strip chomp chop downcase upcase
                                      puts print p pp warn raise fail
                                      require require_relative load autoload
                                      attr_reader attr_writer attr_accessor
                                      private protected public
                                      include extend prepend
                                    ]).freeze

    # Extracts call sites from an AST node tree.
    #
    # Returns method calls found in the tree, ordered by source line number.
    # Used by both RubyAnalyzer (call graph building) and FlowAssembler
    # (execution flow ordering).
    #
    # @example Extracting calls from a method body
    #   parser = Ast::Parser.new
    #   root = parser.parse(source)
    #   calls = Ast::CallSiteExtractor.new.extract(root)
    #   calls.first #=> { receiver: "User", method_name: "find", arguments: ["id"], line: 3, block: false }
    #
    class CallSiteExtractor
      # Extract all call sites from an AST node, ordered by line number.
      #
      # @param node [Ast::Node] The AST node to search
      # @return [Array<Hash>] Call site hashes ordered by line ascending
      def extract(node)
        calls = []
        collect_calls(node, calls)
        calls.sort_by { |c| c[:line] }
      end

      # Extract only significant call sites, filtering out noise.
      #
      # @param node [Ast::Node] The AST node to search
      # @param known_units [Array<String>] Known unit identifiers for relevance filtering
      # @return [Array<Hash>] Filtered call site hashes
      def extract_significant(node, known_units: [])
        calls = extract(node)
        known_set = Set.new(known_units)

        calls.reject do |call|
          INSIGNIFICANT_METHODS.include?(call[:method_name]) &&
            (known_units.empty? || !known_set.include?(call[:receiver]))
        end
      end

      private

      def collect_calls(node, calls)
        return unless node.is_a?(Ast::Node)

        case node.type
        when :send
          calls << {
            receiver: node.receiver,
            method_name: node.method_name,
            arguments: node.arguments || [],
            line: node.line,
            block: false
          }
        when :block
          # The send node in a block gets block: true
          send_child = node.children&.first
          if send_child.is_a?(Ast::Node) && send_child.type == :send
            calls << {
              receiver: send_child.receiver,
              method_name: send_child.method_name,
              arguments: send_child.arguments || [],
              line: send_child.line,
              block: true
            }
          end
          # Also recurse into block body (children[1])
          node.children&.drop(1)&.each { |child| collect_calls(child, calls) }
          return # Don't double-recurse into children
        end

        (node.children || []).each { |child| collect_calls(child, calls) }
      end
    end
  end
end
