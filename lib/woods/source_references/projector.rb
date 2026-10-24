# frozen_string_literal: true

require_relative '../source_line_map'
require_relative '../source_contributors'

module Woods
  module SourceReferences
    # Projects admitted occurrences only through proven original source placement.
    # Missing maps are not identity; sliced/generated/scrubbed text is omitted.
    class Projector
      # @param source_reader [#call] captured original bytes for a relative path
      def initialize(source_reader:)
        @reader = source_reader
      end

      # @param unit [Hash] string-keyed unit with its final annotated source/map
      # @param references [Array<Hash>] admitted raw occurrences, including file_path
      # @return [Array<Hash>] sorted occurrences in published-source coordinates
      def call(unit, references)
        source = unit['source_code']
        return [] if references.empty?
        return [] unless source.is_a?(String)

        @published_offsets = line_offsets(source)

        contributors = SourceContributors.records(unit)
        projected = references.group_by { |record| record.fetch('file_path') }.flat_map do |path, records|
          project_file(unit, path, records, contributors)
        end
        projected.sort_by { |record| sort_key(record) }
      end

      private

      # Verified constants keep their established order; declaration kinds and
      # ambiguous candidates (no single target) follow at the same position.
      def sort_key(record)
        [*record.values_at('line', 'column', 'length'), record['target_type'].to_s, record['target'].to_s,
         record['kind'].to_s, record['confidence'].to_s,
         Array(record['candidates']).map { |candidate| candidate.values_at('target_type', 'target') }]
      end

      def project_file(unit, path, records, contributors)
        original = @reader.call(path)
        placement = placement(unit, path, original, contributors)
        return [] unless placement

        @original_offsets = line_offsets(original)
        records.filter_map { |record| project(record, original, unit['source_code'], placement) }
      end

      def placement(unit, path, original, contributors)
        return unless original.is_a?(String) && original.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        source = unit.fetch('source_code')
        unless contributors.empty?
          fragment = contributors.find { |record| record['file_path'] == path }
          return contributor_placement(source, original, fragment) if fragment

          return
        end
        single_placement(unit, path, original)
      end

      def single_placement(unit, path, original)
        return unless path == unit['file_path']

        source = unit.fetch('source_code')
        return ->(line) { line } if source.b == original.b

        map = unit.fetch('metadata', {})['source_line_map']
        return unless map && map == SourceLineMap.build(original, source)

        ->(line) { SourceLineMap.project(map, line) }
      end

      def contributor_placement(source, original, fragment)
        first = fragment['published_start_byte']
        last = fragment['published_end_byte']
        return unless first.zero? || source.byteslice(first - 1, 1) == "\n"
        return unless source.byteslice(first...last).b == original.b

        ->(line) { fragment['published_start_line'] + line - fragment['source_start_line'] }
      end

      def project(record, original, source, placement)
        first, column, length = record.values_at('line', 'column', 'length')
        bytes = slice(original, @original_offsets, first, column, length)
        return unless bytes

        line = placement.call(first)
        return unless line && contiguous?(placement, first, line, bytes.count("\n"))
        return unless slice(source, @published_offsets, line, column, length)&.b == bytes.b

        record.except('file_path').merge('line' => line)
      end

      def slice(source, offsets, line, column, length)
        first = offsets[line - 1]
        last = offsets[line]
        return unless first && last && column >= 0 && column < last - first

        bytes = source.byteslice(first + column, length)
        bytes if bytes && bytes.bytesize == length
      end

      def line_offsets(source)
        offsets = [0]
        source.b.each_line { |line| offsets << (offsets.last + line.bytesize) }
        offsets
      end

      def contiguous?(placement, first, published, newlines)
        (0..newlines).all? { |offset| placement.call(first + offset) == published + offset }
      end
    end
  end
end
