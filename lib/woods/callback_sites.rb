# frozen_string_literal: true

require 'prism'
require_relative 'method_table'

module Woods
  # Where each model callback is declared in a unit's published
  # `source_code` (#817): the line range of the `before_save :name` style
  # call, in annotated-source coordinates (the same as `metadata.methods`
  # and `metadata.references`), recorded on the callback entry as
  # `declaration`. With the method table it lets a reader tie a changed line
  # to the lifecycle step it declares or defines.
  #
  # Declarations come from one Prism walk of the published text and of each
  # inlined concern block (as {MethodTable} decodes them). Only a literal
  # symbol argument is matched, and only when exactly one call site declares
  # that method for that callback type; a proc, a framework callback, a
  # metaprogrammed or ambiguous declaration keeps no `declaration`. Nothing
  # is executed.
  module CallbackSites
    MACRO = /\A(?:before|after|around)_[a-z_]+\z/
    # Declarations whose runtime chain entry is an `after_commit`.
    COMMIT = /\Aafter_(?:create|update|destroy|save)_commit\z/

    module_function

    # Record declaration sites on the callbacks of a unit about to be written.
    #
    # @param unit [ExtractedUnit]
    # @return [void]
    def record(unit)
      callbacks = unit.metadata[:callbacks] || unit.metadata['callbacks']
      return unless callbacks.is_a?(Array) && callbacks.any?

      sites = call(unit.source_code)
      callbacks.each { |callback| annotate(callback, sites) if callback.is_a?(Hash) }
    end

    # @param source [String, nil] published annotated source
    # @return [Hash{Array(String, String) => Array<Hash>}] [runtime type,
    #   method] => every declaring call's `line` and `end_line`; empty when
    #   the source is absent or does not parse
    def call(source)
      return {} unless source.is_a?(String) && !source.empty?

      parsed = Prism.parse(source)
      return {} if parsed.errors.any?

      sites = Hash.new { |hash, key| hash[key] = [] }
      collect(parsed.value, 0, sites)
      MethodTable.blocks(source.lines(chomp: true)).each do |first_line, text|
        block = Prism.parse(text)
        collect(block.value, first_line - 1, sites) if block.errors.empty?
      end
      sites
    end

    # @param name [String] the declaring macro
    # @return [String] the callback type the runtime chain reports for it
    def runtime_type(name)
      name.match?(COMMIT) ? 'after_commit' : name
    end

    def annotate(callback, sites)
      symbol = callback.key?(:filter) || callback.key?(:type)
      key = symbol ? :declaration : 'declaration'
      callback.delete(key)
      type = (callback[:type] || callback['type']).to_s
      filter = (callback[:filter] || callback['filter']).to_s
      found = sites.fetch([type, filter], [])
      callback[key] = found.first if found.size == 1
    end

    def collect(root, offset, sites)
      Visitor.new(offset, sites).visit(root)
    end

    # Finds receiverless callback macro calls with literal symbol arguments.
    class Visitor < Prism::Visitor
      def initialize(offset, sites)
        super()
        @offset = offset
        @sites = sites
      end

      # @param node [Prism::CallNode]
      # @return [void]
      def visit_call_node(node)
        record(node) if node.receiver.nil? && node.name.to_s.match?(MACRO)
        super
      end

      private

      def record(node)
        type = CallbackSites.runtime_type(node.name.to_s)
        site = { 'line' => node.location.start_line + @offset, 'end_line' => node.location.end_line + @offset }
        Array(node.arguments&.arguments).each do |argument|
          next unless argument.is_a?(Prism::SymbolNode) && argument.unescaped

          @sites[[type, argument.unescaped]] << site
        end
      end
    end
  end
end
