# frozen_string_literal: true

require 'prism'
require 'set'
require_relative 'cache_call_arguments'

module Woods
  module Extractors
    # Finds calls on cache stores a Ruby file obtains itself, rather than
    # through `Rails.cache`: a receiver assigned from `.cache_store`,
    # `ActiveSupport::Cache.lookup_store`, or `ActiveSupport::Cache::*Store.new`
    # (a local, instance or class variable, constant, or a method whose last
    # expression is one), or one of those expressions chained directly.
    #
    # Binding is per file and by name, not by scope. The file is parsed once
    # and walked iteratively, so the cost is linear in its size.
    module CacheStoreCalls
      module_function

      # Files without one of these never parse.
      PREFILTER = /\.cache_store\b|ActiveSupport::Cache(?:\.lookup_store\b|::\w+Store\.new\b)/

      # Store method name => cache call type.
      STORE_METHODS = { read: :read, write: :write, fetch: :fetch, delete: :delete, exist?: :exist }.freeze

      STORE_CLASS = /\A(?:::)?ActiveSupport::Cache::\w+Store\z/
      CACHE_MODULE = /\A(?:::)?ActiveSupport::Cache\z/

      # Assignment nodes whose target is a name a later call can use.
      BINDINGS = {
        Prism::LocalVariableWriteNode => :local, Prism::LocalVariableOrWriteNode => :local,
        Prism::InstanceVariableWriteNode => :variable, Prism::InstanceVariableOrWriteNode => :variable,
        Prism::ClassVariableWriteNode => :variable, Prism::ClassVariableOrWriteNode => :variable,
        Prism::ConstantWriteNode => :constant, Prism::ConstantOrWriteNode => :constant
      }.freeze

      # Receiver reads matched against the bound names of the same kind.
      READS = {
        Prism::LocalVariableReadNode => :local, Prism::InstanceVariableReadNode => :variable,
        Prism::ClassVariableReadNode => :variable, Prism::ConstantReadNode => :constant
      }.freeze

      # @param code [String] Ruby source with comments blanked
      # @return [Array<Hash>] Cache call entries in source order, each with
      #   :type, :key_pattern, :ttl, :options, :store, and :argument_range
      def find(code)
        return [] unless code.match?(PREFILTER)

        nodes = all_nodes(Prism.parse(code).value)
        bound = bound_names(nodes)
        calls = nodes.select { |node| store_call?(node, bound) }.sort_by { |node| node.location.start_offset }
        calls.map { |node| entry(node) }
      end

      def store_call?(node, bound)
        node.is_a?(Prism::CallNode) && STORE_METHODS.key?(node.name) && !node.receiver.nil? &&
          store?(node.receiver, bound)
      end

      def entry(node)
        described = CacheCallArguments.describe(node)
        { type: STORE_METHODS[node.name], key_pattern: described[:key_pattern], ttl: described[:ttl],
          options: described[:options], store: node.receiver.slice, argument_range: described[:argument_range] }
      end

      def all_nodes(root)
        nodes = []
        pending = [root]
        while (node = pending.pop)
          nodes << node
          pending.concat(node.compact_child_nodes)
        end
        nodes
      end

      # @return [Hash{Symbol => Set<Symbol>}] Names bound to a store, by kind
      def bound_names(nodes)
        bound = Hash.new { |hash, kind| hash[kind] = Set.new }
        nodes.each do |node|
          if (kind = BINDINGS[node.class])
            bound[kind] << node.name if store_expression?(node.value)
          elsif node.is_a?(Prism::DefNode) && returns_store?(node.body)
            bound[:method] << node.name
          end
        end
        bound
      end

      def returns_store?(body)
        last = body.is_a?(Prism::StatementsNode) ? body.body.last : body
        return false unless last

        store_expression?(last) || (BINDINGS.key?(last.class) && store_expression?(last.value))
      end

      def store?(receiver, bound)
        receiver = unwrap(receiver)
        if (kind = READS[receiver.class])
          bound[kind].include?(receiver.name)
        elsif receiver.is_a?(Prism::CallNode) && bound[:method].include?(receiver.name) &&
              (receiver.receiver.nil? || receiver.receiver.is_a?(Prism::SelfNode)) && receiver.arguments.nil?
          true
        else
          store_expression?(receiver) || (BINDINGS.key?(receiver.class) && store_expression?(receiver.value))
        end
      end

      def store_expression?(node)
        node = unwrap(node)
        return false unless node.is_a?(Prism::CallNode) && node.receiver

        case node.name
        when :cache_store
          node.arguments.nil? && !(node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :config)
        when :lookup_store then node.receiver.slice.match?(CACHE_MODULE)
        when :new then node.receiver.slice.match?(STORE_CLASS)
        else false
        end
      end

      # `(store = X.cache_store)` reads as its single inner expression.
      def unwrap(node)
        while node.is_a?(Prism::ParenthesesNode) && node.body.is_a?(Prism::StatementsNode) && node.body.body.one?
          node = node.body.body.first
        end
        node
      end
      private_class_method :store_call?, :entry, :all_nodes, :bound_names, :returns_store?, :store?, :store_expression?, :unwrap
    end
  end
end
