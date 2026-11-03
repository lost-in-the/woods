# frozen_string_literal: true

require_relative 'source_line_map'

module Woods
  # File coordinates for line ranges recorded in a unit's annotated
  # `source_code`.
  #
  # The method table, callback and filter declaration sites and test examples
  # record `line`/`end_line` in annotated-source coordinates: the published
  # text with Woods' headers and inlined concern blocks. A reader opening the
  # file needs the file's own line, so each entry also carries:
  #
  # - `file_line` / `file_end_line`: the line in the unit's own file,
  #   translated through `source_line_map`; or, for a definition inside an
  #   inlined concern block, the line in that concern's file;
  # - `file_unit`: present only for an inlined block, naming the concern unit
  #   whose file `file_line` refers to.
  #
  # A line Woods added (a header or a block frame) has no file line and
  # reports nil.
  module FileLines
    # The inlined concern blocks of +source+ and the unit's line map, ready to
    # annotate entries.
    class Locator
      # @param source [String, nil] the unit's published annotated source
      # @param map [Array<Array(Integer, Integer, Integer)>, nil] the unit's
      #   `source_line_map`
      def initialize(source, map)
        @map = map
        @blocks = source.is_a?(String) ? MethodTable.block_ranges(source.lines(chomp: true)) : []
      end

      # Add file coordinates to an entry keyed `line` and `end_line`.
      #
      # @param entry [Hash] string-keyed
      # @return [Hash] the same entry
      def annotate(entry)
        line = entry['line']
        return entry unless line.is_a?(Integer)

        end_line = entry['end_line']
        block = @blocks.find { |first, last, _name| line.between?(first, last) }
        if block
          entry['file_line'] = line - block[0] + 1
          entry['file_end_line'] = end_line.is_a?(Integer) ? end_line - block[0] + 1 : nil
          entry['file_unit'] = block[2]
        else
          entry['file_line'] = SourceLineMap.translate(@map, line)
          entry['file_end_line'] = end_line.is_a?(Integer) ? SourceLineMap.translate(@map, end_line) : nil
        end
        entry
      end
    end

    module_function

    # @param unit [ExtractedUnit]
    # @return [Locator] for the unit's published source and line map
    def for(unit)
      metadata = unit.metadata || {}
      Locator.new(unit.source_code, metadata[:source_line_map] || metadata['source_line_map'])
    end
  end
end
