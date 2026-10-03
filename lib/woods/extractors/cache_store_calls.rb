# frozen_string_literal: true

require 'prism'
require_relative 'cache_call_arguments'

module Woods
  module Extractors
    # Finds calls on cache stores a Ruby file obtains itself, rather than
    # through `Rails.cache`. A store expression is `X.cache_store(...)` (X
    # not `config`), `ActiveSupport::Cache.lookup_store(...)`,
    # `ActiveSupport::Cache::*Store.new(...)`, or an `||`/`or` with a store
    # on either side. A receiver is a store when it is:
    #
    # - a local, instance or class variable, or constant assigned from one;
    # - a method whose last expression is one, assigns one, or reads a bound
    #   variable; an `attr_reader`/`attr_accessor` of a bound instance
    #   variable; or a forwarder or alias of such a method;
    # - a store expression (or an assignment of one) chained directly.
    #
    # Each call records `store` (the receiver at the call site) and
    # `store_origin` (the store expression the receiver was first bound
    # from, in source order; the receiver itself for a chained call).
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
      ORIGIN_LIMIT = 120

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

      ATTR_READERS = %i[attr_reader attr_accessor].freeze

      # @param code [String] Ruby source with comments blanked
      # @return [Array<Hash>] Cache call entries in source order, each with
      #   :type, :key_pattern, :ttl, :options, :store, :store_origin, and
      #   :argument_range
      def find(code)
        return [] unless code.match?(PREFILTER)

        nodes = all_nodes(Prism.parse(code).value).sort_by { |node| node.location.start_offset }
        bound = bound_names(nodes)
        nodes.filter_map { |node| entry(node, bound) }
      end

      def entry(node, bound)
        return unless node.is_a?(Prism::CallNode) && STORE_METHODS.key?(node.name) && node.receiver

        origin = receiver_origin(node.receiver, bound)
        return unless origin

        described = CacheCallArguments.describe(node)
        { type: STORE_METHODS[node.name], key_pattern: described[:key_pattern], ttl: described[:ttl],
          options: described[:options], store: node.receiver.slice, store_origin: origin[0, ORIGIN_LIMIT],
          argument_range: described[:argument_range] }
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

      # Names bound to a store, by kind, each mapped to its origin source.
      # `nodes` are in source order, so the first binding of a name wins.
      #
      # @return [Hash{Symbol => Hash{Symbol => String}}]
      def bound_names(nodes)
        bound = Hash.new { |hash, kind| hash[kind] = {} }
        nodes.each do |node|
          kind = BINDINGS[node.class]
          origin = kind ? store_origin(node.value) : (node.is_a?(Prism::DefNode) && returned_origin(node.body))
          bound[kind || :method][node.name] ||= origin if origin
        end
        propagate_methods(nodes, bound)
        bound
      end

      # Methods that reach a bound store through another name: a reader of a
      # bound instance variable or constant, an attr reader, a forwarder of a
      # bound method, or an alias. Edges are followed breadth first, once.
      def propagate_methods(nodes, bound)
        edges = Hash.new { |hash, name| hash[name] = [] }
        nodes.each do |node|
          case node
          when Prism::DefNode then link_def(node, bound, edges)
          when Prism::AliasMethodNode then link_alias(node.old_name, node.new_name, edges)
          when Prism::CallNode then link_call(node, bound, edges)
          end
        end

        pending = bound[:method].keys
        until pending.empty?
          name = pending.shift
          edges[name].each do |target|
            next if bound[:method].key?(target)

            bound[:method][target] = bound[:method][name]
            pending << target
          end
        end
      end

      def link_def(node, bound, edges)
        last = last_expression(node.body)
        if (kind = READS[last.class])
          origin = bound[kind][last.name]
          bound[:method][node.name] ||= origin if origin
        elsif bare_call?(last)
          edges[last.name] << node.name
        end
      end

      def link_alias(old_name, new_name, edges)
        old_name = literal_name(old_name)
        new_name = literal_name(new_name)
        edges[old_name] << new_name if old_name && new_name
      end

      def link_call(node, bound, edges)
        return unless node.receiver.nil? && node.arguments

        arguments = node.arguments.arguments
        if node.name == :alias_method && arguments.size == 2
          link_alias(arguments[1], arguments[0], edges)
        elsif ATTR_READERS.include?(node.name)
          arguments.each do |argument|
            name = literal_name(argument)
            origin = name && bound[:variable][:"@#{name}"]
            bound[:method][name] ||= origin if origin
          end
        end
      end

      # @return [Symbol, nil] The name a `:sym` or `"str"` argument spells
      def literal_name(node)
        node.unescaped.to_sym if node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)
      end

      def returned_origin(body)
        last = last_expression(body)
        return unless last

        store_origin(last) || (BINDINGS.key?(last.class) && store_origin(last.value)) || nil
      end

      def last_expression(body)
        body.is_a?(Prism::StatementsNode) ? body.body.last : body
      end

      def bare_call?(node)
        node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)) &&
          node.arguments.nil? && node.block.nil?
      end

      # @return [String, nil] The origin of a receiver: its binding's origin,
      #   or its own source when it is a store expression chained directly
      def receiver_origin(receiver, bound)
        inner = unwrap(receiver)
        if (kind = READS[inner.class])
          bound[kind][inner.name]
        elsif bare_call?(inner) && bound[:method].key?(inner.name)
          bound[:method][inner.name]
        elsif store_origin(inner) || (BINDINGS.key?(inner.class) && store_origin(inner.value))
          receiver.slice
        end
      end

      # @return [String, nil] Source of the store expression a value is, or
      #   of the first store side of an `||`/`or`
      def store_origin(node)
        node = unwrap(node)
        return store_origin(node.left) || store_origin(node.right) if node.is_a?(Prism::OrNode)
        return unless node.is_a?(Prism::CallNode) && node.receiver

        node.slice if factory?(node)
      end

      def factory?(node)
        case node.name
        when :cache_store then !(node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :config)
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
      private_class_method :entry, :all_nodes, :bound_names, :propagate_methods, :link_def, :link_alias,
                           :link_call, :literal_name, :returned_origin, :last_expression, :bare_call?, :receiver_origin,
                           :store_origin, :factory?, :unwrap
    end
  end
end
