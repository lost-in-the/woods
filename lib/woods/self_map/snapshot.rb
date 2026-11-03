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
            entry['definition'] == false ? [] : [identity(entry)]
          end
        end.uniq.sort
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
