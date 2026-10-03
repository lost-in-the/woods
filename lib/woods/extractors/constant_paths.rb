# frozen_string_literal: true

require 'prism'
require 'strscan'
require_relative 'line_neutralizer'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Constant paths as dependency-edge targets: recorded whole, as written,
    # then resolved the way Ruby resolves them at the reference site.
    #
    # A unit is identified by its full constant path, so an edge target has to
    # be one too. Recording the last segment of `Ledger::Entry::Create`, or
    # keeping the leading `::` of `"::Ledger::Entry"`, names no unit at all.
    module ConstantPaths
      # One constant read in source.
      #
      # +nesting+ holds the enclosing scope names, innermost first. +call+ is
      # the method the constant receives, +keyword+ the keyword argument it is
      # passed under, and +literal+ marks a string spelling a constant path.
      Reference = Struct.new(:path, :nesting, :call, :keyword, :literal, keyword_init: true)

      # +status+ is +:resolved+ for a loaded class or module, +:value+ for any
      # other constant, +:unresolved+ when nothing loaded answers to the path.
      # +source_file+ is nil for a constant no Ruby file defines.
      # +value+ is the resolved class or module itself.
      Resolution = Struct.new(:target, :status, :source_file, :value, keyword_init: true)

      # The mixin module ActiveSupport::Concern extends onto an including class.
      CLASS_METHODS_SUFFIX = '::ClassMethods'

      # A whole constant chain, not one that continues a dynamic receiver
      # (`widget::Entry`) or a symbol (`:Entry`).
      CHAIN = /(?<![\w:])(?:::)?[A-Z]\w*+(?:::[A-Z]\w*+)*+/
      FOLLOWING_CALL = /\.([a-z_]\w*+[?!]?+)/
      PRECEDING_KEYWORD = /([a-z_]\w*+):[ \t]*+\z/
      # Bytes before a chain that can hold its keyword label.
      KEYWORD_WINDOW = 64

      CONST_SOURCE_LOCATION = Module.instance_method(:const_source_location)

      module_function

      # @param name [String, nil] a constant path, possibly written `::Rooted`
      # @return [String, nil] the path a unit identifier is spelled with
      def normalize(name)
        name&.to_s&.delete_prefix('::')
      end

      # @param name [String] a module name
      # @return [String] the module owning +name+ when it is a `ClassMethods`
      #   mixin, else +name+
      def mixin_owner(name)
        name.end_with?(CLASS_METHODS_SUFFIX) ? name.delete_suffix(CLASS_METHODS_SUFFIX) : name
      end

      # Every constant read in +source+, in source order.
      #
      # @param source [String] Ruby source
      # @return [Array<Reference>]
      def references(source)
        parsed = Prism.parse(source)
        return token_references(source) unless parsed.success?

        [].tap { |found| walk(parsed.value, [], found) }
      rescue SystemStackError
        token_references(source)
      end

      # @param path [String] a constant path as written
      # @param nesting [Array<String>] enclosing scope names, innermost first
      # @param lookup [SourceReferences::RuntimeLookup]
      # @return [Resolution] the loaded constant's own name, or the written
      #   path when nothing loaded answers to it
      def resolve(path, nesting = [], lookup: SourceReferences::RuntimeLookup.new)
        result = lookup.call(path, nesting: nesting, allow_private: true)
        if result[:reason] == 'unloaded_scope'
          nesting = loaded_scopes(nesting, lookup)
          result = lookup.call(path, nesting: nesting, allow_private: true)
        end
        result = aliased(path, nesting, lookup) || result if result[:reason] == 'constant_alias'

        case result[:status] == :resolved ? :resolved : result[:reason]
        when :resolved then Resolution.new(target: result[:target], status: :resolved, value: result[:value],
                                           source_file: source_file(result[:target]))
        when 'non_module_constant' then Resolution.new(target: normalize(path), status: :value)
        else Resolution.new(target: normalize(path), status: :unresolved)
        end
      end

      # A scope that is not loaded declares no constants to find.
      #
      # @return [Array<String>]
      def loaded_scopes(nesting, lookup)
        nesting.select { |scope| lookup.module_object?(lookup.call("::#{scope}", allow_private: true)[:value]) }
      end

      # @return [Hash, nil] the lookup result for the constant an alias names
      def aliased(path, nesting, lookup)
        parent, _, name = path.rpartition('::')
        scope = parent.empty? ? nil : lookup.call(parent, nesting: nesting, allow_private: true)[:value]
        return unless lookup.module_object?(scope) && lookup.reflect(scope, :const_defined?, name, false)
        return if lookup.reflect(scope, :autoload?, name, false)

        value = lookup.reflect(scope, :const_get, name, false)
        canonical = lookup.module_object?(value) && lookup.reflect(value, :name)
        lookup.call("::#{canonical}", allow_private: true) if canonical
      end

      # @return [String, nil] the Ruby file defining +target+
      def source_file(target)
        file = CONST_SOURCE_LOCATION.bind(Object).call(target)&.first
        file if file.is_a?(String)
      rescue NameError
        nil
      end

      def walk(node, nesting, found)
        case node
        when nil then nil
        when Prism::ClassNode, Prism::ModuleNode then walk_declaration(node, nesting, found)
        when Prism::CallNode then walk_call(node, nesting, found)
        when Prism::AssocNode then walk_assoc(node, nesting, found)
        when Prism::ConstantPathNode, Prism::ConstantReadNode then record(node, nesting, found)
        when Prism::ConstantPathWriteNode, Prism::ConstantWriteNode then walk(node.value, nesting, found)
        when Prism::StringNode then record_literal(node, nesting, found)
        else node.compact_child_nodes.each { |child| walk(child, nesting, found) }
        end
      end

      def walk_declaration(node, nesting, found)
        walk(node.superclass, nesting, found) if node.is_a?(Prism::ClassNode)
        name = node.constant_path.location.slice
        return walk(node.body, nesting, found) unless constant?(name)

        scope = name.start_with?('::') ? normalize(name) : [nesting.first, name].compact.join('::')
        walk(node.body, [scope, *nesting], found)
      end

      def walk_call(node, nesting, found)
        receiver = node.receiver
        if constant_node?(receiver)
          record(receiver, nesting, found, call: node.name.to_s)
        else
          walk(receiver, nesting, found)
        end
        walk(node.arguments, nesting, found)
        walk(node.block, nesting, found)
      end

      def walk_assoc(node, nesting, found)
        key = node.key
        if key.is_a?(Prism::SymbolNode) && constant_node?(node.value)
          record(node.value, nesting, found, keyword: key.unescaped)
        else
          node.compact_child_nodes.each { |child| walk(child, nesting, found) }
        end
      end

      def record(node, nesting, found, call: nil, keyword: nil)
        path = node.location.slice
        if constant?(path)
          found << Reference.new(path: path, nesting: nesting, call: call, keyword: keyword, literal: false)
        elsif node.is_a?(Prism::ConstantPathNode)
          walk(node.parent, nesting, found)
        end
      end

      def record_literal(node, nesting, found)
        path = node.unescaped
        return unless path.include?('::') && constant?(path)

        found << Reference.new(path: path, nesting: nesting, literal: true)
      end

      def constant_node?(node)
        node.is_a?(Prism::ConstantPathNode) || node.is_a?(Prism::ConstantReadNode)
      end

      def constant?(path)
        SourceReferences::RuntimeLookup::CONSTANT.match?(path)
      end

      # Unparseable source has no syntax tree and so no nesting: one linear
      # pass over the comment-stripped text keeps the whole written paths.
      def token_references(source)
        text = LineNeutralizer.strip_comments(source)
        scanner = StringScanner.new(text)
        found = []
        while scanner.scan_until(CHAIN)
          start = scanner.pos - scanner.matched_size
          window = [start, KEYWORD_WINDOW].min
          path = scanner.matched
          found << Reference.new(path: path, nesting: [], call: scanner.check(FOLLOWING_CALL) && scanner[1],
                                 keyword: text.byteslice(start - window, window).scrub[PRECEDING_KEYWORD, 1],
                                 literal: false)
        end
        found
      end

      private_class_method :loaded_scopes, :aliased, :walk, :walk_declaration, :walk_call, :walk_assoc, :record, :record_literal,
                           :constant_node?, :constant?, :token_references
    end
  end
end
