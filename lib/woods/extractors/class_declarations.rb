# frozen_string_literal: true

require 'prism'
require_relative '../source_references/runtime_lookup'

module Woods
  module Extractors
    # Structural declaration evidence without loading or evaluating source.
    module ClassDeclarations
      class Unresolved < StandardError; end

      module_function

      # @param source [String] original Ruby source
      # @return [Array<Hash>] class identities, lexical scopes and syntax nodes
      def read(source)
        parsed = Prism.parse(source)
        return [] unless parsed.success?

        Collector.new.call(parsed.value)
      end

      # @param declaration [Hash] record returned by .read
      # @return [String, nil] constant-path parent, including Migration[version]
      def parent_name(declaration)
        parent = declaration.fetch(:node).superclass
        parent = parent.receiver if parent.is_a?(Prism::CallNode) && parent.name == :[]
        constant_name(parent)
      end

      # @param node [Prism::Node, nil] constant syntax
      # @return [String, nil] written constant path, preserving leading ::
      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          parent = node.parent ? constant_name(node.parent) : ''
          "#{parent}::#{node.name}" if parent
        end
      end

      # Qualified declaration receivers follow constant lookup; they do not
      # automatically belong to the innermost syntactic namespace.
      class Collector
        def initialize
          @lookup = SourceReferences::RuntimeLookup.new
          @namespaces = {}
        end

        def call(node, nesting = [], result = [])
          return result unless node
          return result if node.is_a?(Prism::SingletonClassNode) || node.is_a?(Prism::DefNode)

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            name = ClassDeclarations.constant_name(node.constant_path)
            return result unless name

            identifier = declaration_identity(name, nesting)
            @namespaces[identifier] = true
            if node.is_a?(Prism::ClassNode)
              result << { identifier: identifier, nesting: nesting, node: node, source: node.location.slice }
            end
            call(node.body, [identifier, *nesting], result)
          else
            node.compact_child_nodes.each { |child| call(child, nesting, result) }
          end
          result
        end

        private

        def declaration_identity(name, nesting)
          parts = name.delete_prefix('::').split('::')
          return [name.start_with?('::') ? nil : nesting.first, parts.first].compact.join('::') if parts.one?

          leaf = parts.pop
          receiver = if name.start_with?('::')
                       namespace(parts.shift)
                     else
                       lexical_namespace(parts.shift, nesting)
                     end
          parts.each { |part| receiver = namespace("#{receiver}::#{part}") }
          "#{receiver}::#{leaf}"
        end

        def lexical_namespace(name, nesting)
          nesting.each do |scope|
            candidate = "#{scope}::#{name}"
            return namespace(candidate) if @namespaces[candidate]

            result = @lookup.call("::#{scope}", allow_private: true)
            unresolved!(candidate) unless result[:status] == :resolved
            next unless @lookup.reflect(result[:value], :const_defined?, name, false)

            return namespace(candidate)
          end

          # Only after all lexical constant tables can be checked may inherited
          # or root constants supply a receiver. An unloaded scope is unknown.
          result = @lookup.call(name, nesting: nesting, allow_private: true)
          return result[:target] if result[:status] == :resolved
          return namespace(name) if result[:status] == :missing && result[:root_lookup]

          unresolved!(name)
        end

        def namespace(name)
          result = @lookup.call("::#{name}", allow_private: true)
          return result[:target] if result[:status] == :resolved
          return name if @namespaces[name] && result[:status] == :missing

          unresolved!(name)
        end

        def unresolved!(name)
          raise Unresolved, "Unresolved qualified declaration namespace: #{name}"
        end
      end
    end
  end
end
