# frozen_string_literal: true

require_relative 'source_line_map'
require_relative 'source_contributors'

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
  # Placement is used only where it is proven: a `source_line_map`; for a
  # library unit assembled from several files, the primary file's exact
  # fragment in `source_contributors`; or, with no map, the leading lines
  # {SourceLineMap.record} proved are the file verbatim. A missing map alone
  # proves nothing (the published text may be a slice of the file), so such a
  # unit reports nil.
  #
  # A line with no proven file line reports nil: one Woods added (a header or
  # a block frame), real code from a library unit's secondary contributor
  # file (`source_contributors` locates it), or a unit whose placement in its
  # file is unknown. An entry reports `file_end_line` only when its
  # `file_line` is known too.
  module FileLines
    # The inlined concern blocks of +source+ and the unit's proven placement,
    # ready to annotate entries.
    class Locator
      # @param source [String, nil] the unit's published annotated source
      # @param map [Array<Array(Integer, Integer, Integer)>, nil] the unit's
      #   `source_line_map`
      # @param fragments [Array<Hash>] the unit's contributor records, empty
      #   unless it was assembled from several files
      # @param primary [Hash, nil] the record of the unit's own file among them
      # @param identity_lines [Integer, nil] leading lines proven verbatim
      def initialize(source, map, fragments: [], primary: nil, identity_lines: nil)
        @map = map
        @composite = !fragments.empty?
        @primary = primary
        @identity_lines = identity_lines
        @blocks = source.is_a?(String) ? MethodTable.block_ranges(source.lines(chomp: true)) : []
      end

      # Add file coordinates to an entry keyed `line` and `end_line`.
      #
      # @param entry [Hash] string-keyed
      # @return [Hash] the same entry
      def annotate(entry)
        line = entry['line']
        return entry unless line.is_a?(Integer)

        end_line = entry['end_line'] if entry['end_line'].is_a?(Integer)
        block = @blocks.find { |first, last, _name| line.between?(first, last) }
        block ? in_block(entry, block, line, end_line) : in_file(entry, line, end_line)
        entry
      end

      private

      # An inlined concern block is the concern's file line for line.
      def in_block(entry, block, line, end_line)
        first, _last, name = block
        entry['file_line'] = line - first + 1
        entry['file_end_line'] = end_line && (end_line - first + 1)
        entry['file_unit'] = name
      end

      def in_file(entry, line, end_line)
        entry['file_line'] = file_line(line)
        entry['file_end_line'] = entry['file_line'] && end_line && file_line(end_line)
      end

      def file_line(line)
        if @composite
          # The map was built against the whole concatenation and can pair
          # the primary file's lines with another contributor's.
          return unless @primary

          first = @primary['published_start_line']
          return unless line.between?(first, @primary['published_end_line'])

          @primary['source_start_line'] + line - first
        elsif @map
          SourceLineMap.translate(@map, line)
        elsif @identity_lines
          line if line <= @identity_lines
        end
      end
    end

    module_function

    # @param unit [ExtractedUnit]
    # @return [Locator] for the unit's published source and proven placement
    def for(unit)
      metadata = unit.metadata || {}
      map = metadata[:source_line_map] || metadata['source_line_map']
      fragments = contributor_records(unit)
      Locator.new(unit.source_code, map, fragments: fragments, primary: primary_fragment(unit, fragments),
                                         identity_lines: unit.source_identity_lines)
    end

    # @return [Array<Hash>] validated contributor records; an invalid set is
    #   still a composite, with no placement trusted
    def contributor_records(unit)
      SourceContributors.records(unit)
    rescue SourceContributors::Invalid
      [{}]
    end

    # @return [Hash, nil] the record of the unit's own file
    def primary_fragment(unit, fragments)
      path = unit.file_path.to_s
      fragments.find do |record|
        file = record['file_path']
        file && (path == file || path.end_with?("/#{file}"))
      end
    end
  end
end
