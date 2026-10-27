# frozen_string_literal: true

require 'digest'
require 'json'
require 'prism'
require 'set'

module Woods
  module Extractors
    # What a Ruby source contributes to the constant tables, read from the
    # syntax tree.
    #
    # An incremental run uses it to tell whether an edit can move what a render
    # call resolves to. Resolution reads the loaded constant tables, so only an
    # edit that defines, redefines or re-parents a constant can reach it. The
    # body of a method cannot.
    #
    # The footprint is a map from a qualified constant name to a fingerprint of
    # what defines it: the superclass and the ancestry calls (`include`,
    # `extend`, `prepend`) of a class or module, the value of an assignment, a
    # visibility declaration. Comparing the footprint of a file before and
    # after an edit gives the constants the edit touched ({.touched_names}).
    #
    # Some Ruby cannot be read this way: a constant created by name at run time
    # (`const_set`), an autoload, a method named like a constant (a Phlex Kit
    # method), a syntax error. Those make the footprint +opaque+, and a caller
    # must assume the edit touched anything.
    #
    # @example
    #   before = ConstantFootprint.call("class Card < Base\n  def a = 1\nend")
    #   after = ConstantFootprint.call("class Card < Base\n  def a = 2\nend")
    #   ConstantFootprint.touched_names(before, after) # => #<Set: {}>
    class ConstantFootprint < Prism::Visitor
      # @!attribute definitions
      #   @return [Hash{String => Array<String>}] qualified name => sorted fingerprints
      # @!attribute opaque
      #   @return [Boolean] whether the source defines constants in a way the tree cannot show
      Result = Struct.new(:definitions, :opaque, keyword_init: true)

      ANCESTRY_CALLS = %i[include extend prepend].freeze
      EVAL_CALLS = %i[class_eval module_eval class_exec module_exec].freeze
      VISIBILITY_CALLS = %i[private_constant public_constant deprecate_constant].freeze
      OPAQUE_CALLS = %i[const_set remove_const autoload const_missing].freeze
      CAPITALIZED = /\A[[:upper:]]/
      # Fingerprints of `module X` and a superclass-less `class X` with no ancestry calls.
      PLAIN_REOPENINGS = [['module', []], ['class<', []]].map do |parts|
        Digest::SHA256.hexdigest(JSON.generate(parts))[0, 16]
      end.freeze

      # @param source [String] Ruby source
      # @return [Result]
      def self.call(source)
        parsed = Prism.parse(source.to_s)
        return Result.new(definitions: {}, opaque: true) unless parsed.errors.empty?

        visitor = new
        parsed.value.accept(visitor)
        visitor.result
      end

      # The last segment of every constant whose definition differs between two
      # footprints. A constant is defined by its last segment; its namespaces
      # must already exist.
      #
      # A file that wraps its classes in a namespace reopens the namespace and
      # defines nothing by it, which a footprint alone cannot tell from creating
      # it. +existing+ answers whether a namespace was already defined before
      # the edit, so reopening it plainly is not counted.
      #
      # @param before [Result]
      # @param after [Result]
      # @param existing [#call] (qualified name) => whether the constant was defined before the edit
      # @return [Set<String>, nil] segment names; nil when either side is opaque
      def self.touched_names(before, after, existing: ->(_name) { false })
        touched_constants(before, after, existing: existing)&.to_set { |name| name.split('::').last }
      end

      # Qualified names keep unrelated ancestors with the same leaf distinct.
      # @return [Set<String>, nil] nil when either footprint is opaque
      def self.touched_constants(before, after, existing: ->(_name) { false })
        return nil if before.opaque || after.opaque

        (before.definitions.keys | after.definitions.keys).each_with_object(Set.new) do |name, touched|
          prints = after.definitions[name]
          next if before.definitions[name] == prints
          next if name.empty? || (before.definitions[name].nil? && reopening?(prints) && existing.call(name))

          touched.add(name)
        end
      end

      def self.reopening?(prints)
        prints.all? { |print| PLAIN_REOPENINGS.include?(print) }
      end
      private_class_method :reopening?

      def initialize
        super
        @nesting = []
        @ancestry = [[]]
        @definitions = Hash.new { |hash, key| hash[key] = [] }
        @opaque = false
      end

      # @return [Result]
      def result
        Result.new(definitions: @definitions.transform_values { |prints| prints.uniq.sort }, opaque: @opaque)
      end

      def visit_class_node(node)
        scope(node.constant_path, "class<#{node.superclass&.slice}") { super }
      end

      def visit_module_node(node)
        scope(node.constant_path, 'module') { super }
      end

      def visit_constant_write_node(node)
        define(node.name.to_s, "=#{node.value.slice}")
        super
      end

      def visit_constant_path_write_node(node)
        define(path_name(node.target), "=#{node.value.slice}")
        super
      end

      def visit_constant_or_write_node(node)
        define(node.name.to_s, "||=#{node.value.slice}")
        super
      end

      def visit_constant_and_write_node(node)
        define(node.name.to_s, "&&=#{node.value.slice}")
        super
      end

      def visit_constant_operator_write_node(node)
        define(node.name.to_s, "#{node.binary_operator}=#{node.value.slice}")
        super
      end

      def visit_constant_path_or_write_node(node)
        define(path_name(node.target), "||=#{node.value.slice}")
        super
      end

      def visit_constant_path_and_write_node(node)
        define(path_name(node.target), "&&=#{node.value.slice}")
        super
      end

      def visit_constant_path_operator_write_node(node)
        define(path_name(node.target), "#{node.binary_operator}=#{node.value.slice}")
        super
      end

      def visit_multi_write_node(node)
        (node.lefts + [node.rest].compact + node.rights).each do |target|
          name = target_name(target)
          define(name, "multi=#{node.value.slice}") if name
        end
        super
      end

      def visit_def_node(node)
        @opaque = true if node.name.to_s.match?(CAPITALIZED) || node.name == :const_missing
        super
      end

      def visit_call_node(node)
        name = node.name
        @opaque = true if OPAQUE_CALLS.include?(name)
        record_ancestry(node) if ANCESTRY_CALLS.include?(name)
        record_eval(node) if EVAL_CALLS.include?(name) && node.receiver
        record_visibility(node) if VISIBILITY_CALLS.include?(name)
        super
      end

      private

      def scope(constant_path, fingerprint)
        name = path_name(constant_path)
        outer = @nesting
        @nesting = name.start_with?('::') ? [name.delete_prefix('::')] : outer + [name]
        @ancestry.push([])
        yield
        define_current(fingerprint, @ancestry.pop)
      ensure
        @nesting = outer
      end

      def define_current(fingerprint, ancestry)
        @definitions[@nesting.join('::')] << digest([fingerprint, ancestry.sort])
      end

      def define(name, fingerprint)
        @definitions[qualify(name)] << digest(fingerprint)
      end

      def qualify(name)
        name.start_with?('::') ? name.delete_prefix('::') : (@nesting + [name]).join('::')
      end

      def path_name(path)
        path.full_name
      rescue StandardError
        @opaque = true
        '?'
      end

      def target_name(target)
        case target
        when Prism::ConstantTargetNode then target.name.to_s
        when Prism::ConstantPathTargetNode then target.full_name
        end
      rescue StandardError
        @opaque = true
        nil
      end

      # Ancestry changes the lookup of every class that inherits the receiver,
      # wherever the call sits (a body, a `included` block, a method), so it is
      # part of the enclosing class's fingerprint. A receiver other than self
      # names the class it changes.
      def record_ancestry(node)
        receiver = node.receiver
        return @ancestry.last << node.slice if receiver.nil? || receiver.is_a?(Prism::SelfNode)

        name = constant_receiver(receiver)
        return @opaque = true unless name

        @definitions[name.delete_prefix('::')] << digest(['ancestry', node.slice])
      end

      def record_eval(node)
        name = constant_receiver(node.receiver)
        return @opaque = true unless name

        @definitions[name.delete_prefix('::')] << digest(['eval', node.slice])
      end

      def constant_receiver(receiver)
        case receiver
        when Prism::ConstantReadNode then receiver.name.to_s
        when Prism::ConstantPathNode then path_name(receiver)
        end
      end

      def record_visibility(node)
        symbols = Array(node.arguments&.arguments)
        return @opaque = true unless symbols.all?(Prism::SymbolNode)

        symbols.each { |symbol| define(symbol.unescaped, "visibility:#{node.name}") }
      end

      def digest(parts)
        Digest::SHA256.hexdigest(JSON.generate(parts))[0, 16]
      end
    end
  end
end
