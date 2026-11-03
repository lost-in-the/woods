# frozen_string_literal: true

require_relative '../impact/artifacts'

module Woods
  module SelfMap
    # Lightweight typed summaries from one caller-owned pinned generation.
    class Snapshot
      attr_reader :reader, :entries

      def initialize(reader)
        @reader = reader
        @entries = reader.units
        definitions = entries.select { |entry| %w[ruby_class ruby_module].include?(entry['type']) }
        @owners = definitions.group_by { |entry| entry['identifier'] }
      end

      def provenance
        { 'generation' => reader.generation_number,
          'source_checksum' => reader.manifest.dig('provenance', 'source_checksum'),
          'manifest_checksum' => reader.external_dependency_checksum }
      end

      def health
        reader.manifest['self_map'] || {}
      end

      def graph
        @graph ||= Woods::Impact::Artifacts.new(reader).read('dependency_graph.json')
      end

      def seeds(paths)
        entries.select { |entry| paths.include?(entry['file_path']) }.flat_map do |entry|
          case entry['type']
          when 'ruby_file' then [identity(entry)]
          when 'ruby_method' then owners(entry).map { |owner| identity(owner) }
          else
            definition_seeds(entry)
          end
        end.uniq.sort
      end

      # Reopenings retain their occurrence identity, but consumers name the
      # canonical definition. Seed both only when that typed identity exists.
      def definition_seeds(entry)
        return [] if entry['definition'] == false && !mixin_definition?(entry)

        canonical = @owners.fetch(entry['canonical_identifier'], []).select { |owner| owner['type'] == entry['type'] }
        [identity(entry)] + canonical.map { |owner| identity(owner) }
      end

      # Older retained maps misclassified mixin-only modules. Their published
      # relationship is still usable without decoding or rewriting source units.
      def mixin_definition?(entry)
        Array(graph.fetch('edges', {})[entry['identifier']]).any? do |edge|
          edge.is_a?(Hash) && %w[include extend].include?(edge['via'])
        end
      end

      def owners(method)
        @owners.fetch(method['namespace'], [])
      end

      def identity(entry)
        entry.values_at('identifier', 'type')
      end

      def mapped_paths
        entries.map { |entry| entry['file_path'] }.uniq
      end
    end
  end
end
