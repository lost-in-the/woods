# frozen_string_literal: true

require 'prism'
require 'set'

module Woods
  # The qualified name of each module and class a source declares, read in
  # source order without evaluating anything.
  #
  # A plain name nests in the innermost enclosing body (`module Billing;
  # class Invoice` is +Billing::Invoice+). A qualified name's first constant
  # is looked up the way Ruby looks it up, as far as the source can settle
  # it: the innermost body's own constant when this source has declared it,
  # else an enclosing module of that name, else the nested reading. So
  # `module Billing; class Billing::Invoice` is +Billing::Invoice+, while
  # `module Billing; module Billing; end; class Billing::Invoice` is
  # +Billing::Billing::Invoice+. A leading `::` is absolute.
  #
  # A nearer constant the source does not declare may come from another
  # file, so a declaration elsewhere in the source does not override the
  # nested reading: `module Billing; class Invoice::Line` stays
  # +Billing::Invoice::Line+ even when the file also declares a top-level
  # +Invoice+. A prefix a superclass supplies keeps the nested reading too.
  # One case only the runtime can tell from the bug this rule fixes:
  # `module Billing; class Billing::Invoice` is read as +Billing::Invoice+
  # even when another file declares +Billing::Billing+, which is safe on a
  # Zeitwerk-managed path because `billing/invoice.rb` must define
  # +Billing::Invoice+.
  #
  # @example
  #   names = DeclarationName.new
  #   names.declare('Billing', [])                     # => "Billing"
  #   names.declare('Billing::Invoice', ['Billing'])   # => "Billing::Invoice"
  #   names.declare('Invoice::Line', ['Billing'])      # => "Billing::Invoice::Line"
  class DeclarationName
    # The constant path a declaration writes, built from its Prism syntax
    # (`A::B`, `::A::B`), or nil for a path with a part that is not a
    # constant (`self::A`, `base::A`).
    #
    # @param node [Prism::Node, nil] a ClassNode's or ModuleNode's constant_path
    # @return [String, nil]
    def self.path(node)
      case node
      when Prism::ConstantReadNode then node.name.to_s
      when Prism::ConstantPathNode
        parent = node.parent ? path(node.parent) : ''
        "#{parent}::#{node.name}" if parent
      end
    end

    def initialize
      @declared = Set.new
    end

    # Name a declaration and remember it for the declarations after it.
    #
    # @param path [String] the constant path as written: `B`, `A::B`, `::A::B`
    # @param nesting [Array<String>] qualified names of the enclosing class
    #   and module bodies, outermost first
    # @return [String] the qualified name
    def declare(path, nesting)
      record(resolve(path, nesting))
    end

    # The qualified name a declaration at +path+ has inside +nesting+,
    # without remembering it.
    #
    # @param path [String] the constant path as written
    # @param nesting [Array<String>] enclosing qualified names, outermost first
    # @return [String]
    def resolve(path, nesting)
      return path.delete_prefix('::') if path.start_with?('::') || nesting.empty?

      first, rest = path.split('::', 2)
      scope = rest && settled_scope(first, nesting)
      scope ? "#{scope}::#{rest}" : "#{nesting.last}::#{path}"
    end

    # The module a qualified declaration's first constant names, when this
    # source settles it: the innermost body's own constant, or an enclosing
    # module itself. Past a nearer candidate the source does not declare,
    # any other declaration could be shadowed by a constant another file
    # defines there, so nil keeps the nested reading.
    #
    # @return [String, nil]
    def settled_scope(first, nesting)
      candidates = nesting.reverse.map { |outer| "#{outer}::#{first}" } << first
      return candidates.first if @declared.include?(candidates.first)

      candidates.drop(1).find { |candidate| nesting.include?(candidate) }
    end
    private :settled_scope

    # Remember a qualified name as declared.
    #
    # @param name [String]
    # @return [String] +name+
    def record(name)
      @declared << name
      name
    end

    # @param name [String] a qualified module or class name
    # @return [Boolean] whether a declaration so far has this name
    def declared?(name)
      @declared.include?(name)
    end
  end
end
