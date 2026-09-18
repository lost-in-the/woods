# frozen_string_literal: true

module Woods
  module Resilience
    class GraphInvariantValidator
      # Set-membership and index agreement checks, sharing the validator
      # diagnostics and typed nodes. Keeping these separate leaves graph
      # edge/variant validation in the main validator.
      module MembershipChecks
        private

        def validate_membership(section, expected, scalar: false)
          actual = object_section(section).each_with_object({}) do |(key, entries), result|
            entries = [entries] if scalar && entries.is_a?(String)
            values = membership_entries(key, entries, section)
            result[key] = values if values
          end
          (expected.keys | actual.keys).each do |key|
            compare_membership(section, key, expected.fetch(key, Set.new), actual.fetch(key, Set.new))
          end
        end

        def compare_membership(section, key, wanted, recorded)
          (wanted - recorded).each { |id| error("#{section}[#{key.inspect}]", "missing #{id.inspect}") }
          (recorded - wanted).each { |id| error("#{section}[#{key.inspect}]", "unexpected #{id.inspect}") }
        end

        def membership_entries(key, entries, section)
          return entries.to_set if name?(key) && entries.is_a?(Array) && entries.all? { |entry| name?(entry) }

          error("#{section}[#{key.inspect}]", 'expected a named bucket containing identifiers')
          nil
        end

        def validate_index_agreement
          unless @index_entries.is_a?(Array)
            error('unit indexes', 'expected typed index entries')
            return
          end

          entries = {}
          @index_entries.each { |entry| collect_index_entry(entry, entries) }
          (@typed_nodes.keys - entries.keys).each do |identifier, type|
            error('unit indexes', "graph node #{type}:#{identifier} is not indexed")
          end
          (entries.keys - @typed_nodes.keys).each do |identifier, type|
            error('nodes', "missing indexed unit #{type}:#{identifier}")
          end
        end

        def collect_index_entry(entry, entries)
          unless typed_entry?(entry)
            error('unit indexes', 'entry requires a nonempty identifier and type')
            return
          end
          key = [entry['identifier'], entry['type']]
          error('unit indexes', "duplicate typed entry #{key.last}:#{key.first}") if entries.key?(key)
          entries[key] = entry
          node = @typed_nodes[key]
          return unless node && entry.key?('file_path') && node['file_path'] != entry['file_path']

          error('unit indexes', "file_path differs for #{key.last}:#{key.first}")
        end

        def typed_entry?(entry)
          entry.is_a?(Hash) && name?(entry['identifier']) && name?(entry['type'])
        end
      end
    end
  end
end
