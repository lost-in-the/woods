# frozen_string_literal: true

module Woods
  module Resilience
    class GraphInvariantValidator
      # Collect typed primary/variant identities without normalizing malformed
      # records away; derive type and file membership from those identities.
      module NodeChecks
        private

        def collect_nodes
          object_section('nodes').each do |identifier, node|
            type = register_node(identifier, node, "nodes[#{identifier.inspect}]")
            @primary_types[identifier] = type if type
          end
          @variants = @graph.fetch('variants', [])
          unless @variants.is_a?(Array)
            error('variants', 'expected an array')
            @variants = []
          end
          @variants.each_with_index { |record, index| collect_variant(record, index) }
        end

        def collect_variant(record, index)
          label = "variants[#{index}]"
          unless record.is_a?(Hash)
            error(label, 'expected an object')
            return
          end

          identifier = record['identifier']
          error(label, "missing primary node for #{identifier.inspect}") unless @primary_types.key?(identifier)
          register_node(identifier, record, label)
        end

        def register_node(identifier, node, label)
          unless name?(identifier) && node.is_a?(Hash) && name?(node['type'])
            error(label, 'expected a nonempty identifier and an object with a nonempty type')
            return
          end
          type = node['type']
          key = [identifier, type]
          if @typed_nodes.key?(key)
            error(label, "duplicate typed node #{type}:#{identifier}")
            return
          end

          @typed_nodes[key] = node
          @expected_types[type].add(identifier)
          path = node['file_path']
          if path.is_a?(String)
            @expected_files[path].add(identifier)
          elsif !path.nil?
            error(label, 'file_path must be a string or null')
          end
          type
        end
      end
    end
  end
end
