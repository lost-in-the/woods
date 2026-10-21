# frozen_string_literal: true

require_relative 'chunk'
require_relative '../markdown/line_scan'

module Woods
  module Chunking
    # Chunks a Markdown `doc` unit by heading section, so retrieval returns the
    # section that answers a query instead of the whole document.
    #
    # A section runs from its heading line to the line before the next heading
    # of any level. Text before the first heading is its own section. A section
    # longer than +max_chars+ is split on line boundaries into `_part_N`
    # chunks; a single line longer than the cap is cut by characters.
    #
    # @example
    #   chunks = MarkdownSectionChunker.new(unit).chunk
    #   chunks.map { |c| c.metadata[:heading] } # => [nil, "Setup", "Usage"]
    class MarkdownSectionChunker
      # Roughly 1,500 tokens at four characters per token.
      DEFAULT_MAX_CHARS = 6000

      # @param unit [ExtractedUnit] a `doc` unit with Markdown source_code
      # @param max_chars [Integer] hard ceiling on one chunk's content length
      def initialize(unit, max_chars: DEFAULT_MAX_CHARS)
        raise ArgumentError, 'max_chars must be positive' unless max_chars.positive?

        @unit = unit
        @max_chars = max_chars
      end

      # @return [Array<Chunk>] ordered section chunks; empty for a blank document
      def chunk
        source = @unit.source_code.to_s
        return [] if source.strip.empty?

        lines = source.lines
        sections(Markdown::LineScan.call(source).headings, lines.size).each_with_index.flat_map do |section, index|
          content = lines[(section[:start_line] - 1)...section[:end_line]].join
          next [] if content.strip.empty?

          section_chunks(content, section, index)
        end
      end

      private

      # @return [Array<Hash>] chunk metadata per section, in document order
      def sections(headings, line_count)
        starts = headings.map { |heading| heading[:line] } + [line_count + 1]
        found = heading_sections(headings, starts)
        return found if starts.first == 1

        [{ heading: nil, level: 0, heading_path: [], anchor: nil, start_line: 1, end_line: starts.first - 1 }] + found
      end

      def heading_sections(headings, starts)
        anchors = Hash.new(0)
        path = []
        headings.each_with_index.map do |heading, index|
          path = path.take_while { |entry| entry[:level] < heading[:level] } + [heading]
          { heading: heading[:text], level: heading[:level], heading_path: path.map { |entry| entry[:text] },
            anchor: unique_anchor(heading[:text], anchors), start_line: heading[:line],
            end_line: starts[index + 1] - 1 }
        end
      end

      # The anchor a Markdown renderer gives the heading, numbered on repeats.
      def unique_anchor(text, seen)
        slug = text.downcase.delete('^a-z0-9 _-').tr(' ', '-')
        count = seen[slug]
        seen[slug] += 1
        count.zero? ? slug : "#{slug}-#{count}"
      end

      def section_chunks(content, section, index)
        return [build(content, :"section_#{index}", section)] if content.length <= @max_chars

        slices(content).each_with_index.map do |slice, part|
          build(slice, :"section_#{index}_part_#{part}", section.merge(part: part))
        end
      end

      def build(content, chunk_type, metadata)
        Chunk.new(content: content, chunk_type: chunk_type, parent_identifier: @unit.identifier,
                  parent_type: @unit.type, metadata: metadata)
      end

      def slices(content)
        content.each_line.with_object(['']) do |line, parts|
          pieces(line).each do |piece|
            parts << String.new if parts.last.length + piece.length > @max_chars && !parts.last.empty?
            parts[-1] += piece
          end
        end
      end

      def pieces(line)
        return [line] if line.length <= @max_chars

        (0...line.length).step(@max_chars).map { |offset| line[offset, @max_chars] }
      end
    end
  end
end
