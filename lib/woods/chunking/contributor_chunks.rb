# frozen_string_literal: true

require_relative 'chunk'
require_relative '../source_contributors'

module Woods
  module Chunking
    # Exact physical attribution for contiguous slices of validated contributors.
    # Generated composite headers and cross-file content never get a physical span.
    module ContributorChunks
      module_function

      def chunks(unit)
        SourceContributors.records(unit).each_with_index.map do |record, index|
          first = record.fetch('published_start_byte')
          last = record.fetch('published_end_byte')
          Chunk.new(content: unit.source_code.byteslice(first...last), chunk_type: :"contributor_#{index}",
                    parent_identifier: unit.identifier, parent_type: unit.type,
                    metadata: location(unit, first, last))
        end
      end

      # Preserve existing bounded chunks only if they cover every raw byte once,
      # in contributor order. Caller-supplied ranges never authorize citations.
      def ensure!(unit)
        records = SourceContributors.records(unit)
        return if records.empty?

        unit.chunks = chunks(unit).map(&:to_h) unless complete_coverage?(unit, records)
        unit.chunks.each do |chunk|
          range = published_range(chunk)
          chunk[:metadata] = (chunk[:metadata] || {}).merge(location(unit, range[:start_byte], range[:end_byte]))
        end
      end

      def complete_coverage?(unit, records)
        remaining = unit.chunks.dup
        records.all? do |record|
          cursor = record['published_start_byte']
          while cursor < record['published_end_byte']
            chunk = remaining.shift
            return false unless chunk

            span = published_range(chunk)
            return false unless contiguous?(unit, chunk, span, cursor, record['published_end_byte'])

            cursor = span[:end_byte]
          end
          true
        end && remaining.empty?
      end

      def contiguous?(unit, chunk, span, cursor, last)
        span[:start_byte] == cursor && span[:end_byte].is_a?(Integer) &&
          span[:end_byte] > cursor && span[:end_byte] <= last &&
          unit.source_code.byteslice(cursor...span[:end_byte]) == chunk[:content]
      end

      def published_range(chunk)
        metadata = SourceContributors.field(chunk, :metadata) || {}
        span = SourceContributors.field(metadata, :published_location)
        span.is_a?(Hash) ? span.transform_keys(&:to_sym) : {}
      end

      def location(unit, first, last)
        physical = SourceContributors.physical_span(unit, start_byte: first, end_byte: last)
        return {} unless physical

        record = SourceContributors.records(unit).find { |entry| entry['file_path'] == physical[:file_path] }
        physical = physical.merge(start_byte: first - record['published_start_byte'],
                                  end_byte: last - record['published_start_byte'])
        { physical_location: physical, published_location: { start_byte: first, end_byte: last } }
      end

      # Offsets are relative to this chunk, including for a second splitting pass.
      def slice_metadata(metadata, source, first, last)
        metadata = symbol_keys(metadata)
        physical = symbol_keys(metadata[:physical_location])
        published = symbol_keys(metadata[:published_location])
        clean = metadata.except(:physical_location, :published_location)
        return clean unless mapped_slice?(physical, published, source, first, last)

        clean.merge(physical_location: physical_slice(physical, source, first, last),
                    published_location: { start_byte: published[:start_byte] + first,
                                          end_byte: published[:start_byte] + last })
      end

      def physical_slice(physical, source, first, last)
        start_line = physical[:start_line] + source.byteslice(0...first).count("\n")
        end_line = start_line + source.byteslice(first...last).delete_suffix("\n").count("\n")
        physical.merge(start_byte: physical[:start_byte] + first, end_byte: physical[:start_byte] + last,
                       start_line: start_line, end_line: end_line)
      end

      def symbol_keys(value)
        value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {}
      end

      def mapped_slice?(physical, published, source, first, last)
        integers = [physical[:start_byte], physical[:end_byte], physical[:start_line],
                    published[:start_byte], published[:end_byte]]
        integers.all?(Integer) &&
          [physical, published].all? { |span| span[:end_byte] - span[:start_byte] == source.bytesize } &&
          first >= 0 && last > first && last <= source.bytesize
      end

      # Re-derive spans from the published source when hydrating a metadata dump.
      def vector_metadata(unit, chunk_metadata)
        return {} unless SourceContributors.multiple?(unit)

        span = published_range(metadata: chunk_metadata)
        facts = location(unit, span[:start_byte], span[:end_byte])
        { source_paths: SourceContributors.paths(unit),
          file_path: facts.dig(:physical_location, :file_path) }.merge(facts)
      end
      private_class_method :complete_coverage?, :contiguous?, :mapped_slice?, :physical_slice, :symbol_keys
    end
  end
end
