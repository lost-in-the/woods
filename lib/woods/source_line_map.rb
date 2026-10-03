# frozen_string_literal: true

module Woods
  # Maps a line of a unit's annotated `source_code` back to the line of the
  # file it was read from.
  #
  # Extractors prepend headers (routes, filters, schema, a type banner) and
  # insert commented concern blocks after the class line, so a line number
  # counted in `source_code` is offset from the file a reader opens. The map is
  # recorded while the file is still readable and stored in
  # `metadata[:source_line_map]` only when the two differ, so a unit whose
  # source is the file verbatim serializes as it always did.
  #
  # The map is a list of runs, `[annotated_start, original_start, length]`,
  # 1-based and ordered by `annotated_start`. Every line an annotation adds is
  # a comment or blank, so the code lines of the two texts are the same lines
  # in the same order and any in-order embedding pairs them correctly.
  module SourceLineMap
    module_function

    # @param original [String, nil] the file's content
    # @param annotated [String, nil] the unit's `source_code`
    # @return [Array<Array(Integer, Integer, Integer)>, nil] the runs, or nil
    #   when no line moved or the annotated text does not contain the file
    def build(original, annotated)
      return nil if original.nil? || annotated.nil?

      source = original.b.lines(chomp: true)
      composite = annotated.b.lines(chomp: true)
      return nil if source == composite

      pairs = embed(source, composite)
      return nil unless pairs

      runs = runs_of(pairs)
      runs.size == 1 && runs.first[0] == runs.first[1] ? nil : runs
    end

    # @param map [Array<Array(Integer, Integer, Integer)>, nil]
    # @param line [Integer, nil] a line of the annotated source
    # @return [Integer, nil] the file's line; +line+ itself without a map; nil
    #   for a line an annotation added
    def translate(map, line)
      return line if line.nil? || map.nil? || map.empty?

      start, original_start, length = run_before(map, line)
      start && line < start + length ? original_start + (line - start) : nil
    end

    # Store the map for +unit+ in its metadata, or remove a stale one.
    #
    # @param unit [Woods::ExtractedUnit] a unit whose `file_path` is still the
    #   absolute path its source was read from
    # @return [void]
    def record(unit)
      map = build(read(unit.file_path), unit.source_code)
      if map
        unit.metadata[:source_line_map] = map
      else
        unit.metadata.delete(:source_line_map)
      end
    end

    # Latest-match embedding of every file line into the annotated lines,
    # walking both backwards. One pass: the annotated cursor only moves back.
    #
    # @return [Array<Array(Integer, Integer)>, nil] `[annotated, original]`
    #   line pairs in order, or nil when a file line has no place
    def embed(source, composite)
      cursor = composite.size - 1
      pairs = []
      (source.size - 1).downto(0) do |index|
        cursor -= 1 while cursor >= 0 && composite[cursor] != source[index]
        return nil if cursor.negative?

        pairs << [cursor + 1, index + 1]
        cursor -= 1
      end
      pairs.reverse!
    end

    # @return [Array<Array(Integer, Integer, Integer)>]
    def runs_of(pairs)
      pairs.each_with_object([]) do |(annotated, original), runs|
        last = runs.last
        if last && annotated == last[0] + last[2] && original == last[1] + last[2]
          last[2] += 1
        else
          runs << [annotated, original, 1]
        end
      end
    end

    # @return [Array(Integer, Integer, Integer), nil] the last run starting
    #   at or before +line+
    def run_before(map, line)
      after = map.bsearch_index { |run| run[0] > line } || map.size
      after.zero? ? nil : map[after - 1]
    end

    # @return [String, nil] the file's bytes, or nil when it cannot be read
    def read(path)
      return nil unless path.is_a?(String) && File.file?(path)

      File.binread(path)
    rescue SystemCallError
      nil
    end

    private_class_method :embed, :runs_of, :run_before, :read
  end
end
