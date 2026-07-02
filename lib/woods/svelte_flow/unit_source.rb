# frozen_string_literal: true

module Woods
  module SvelteFlow
    # Resolves the source code to display for a unit in the visualization.
    #
    # Prefers the live file on disk (keyed off the unit's own extracted
    # file_path — never a client-supplied path — so this cannot become an
    # arbitrary-file read) and falls back to the extraction-time snapshot when
    # the file isn't readable (e.g. the offline export opened on another
    # machine). The leading `annotate` schema block is stripped either way:
    # the visualization already renders columns structurally, so the block
    # only duplicates them.
    module UnitSource
      module_function

      # Matches the `# == Schema Information` header emitted by the annotate gem.
      ANNOTATE_HEADER_RE = /^#\s*==\s*Schema Info/

      # Resolve the display source for a unit.
      #
      # @param unit [Hash] Extracted unit data (string or symbol keys)
      # @return [Hash] { 'filePath' =>, 'sourceCode' =>, 'live' => }
      def resolve(unit)
        file_path = unit['file_path'] || unit[:file_path]
        live = readable?(file_path)
        raw = live ? File.read(file_path, encoding: Encoding::UTF_8) : unit['source_code'] || unit[:source_code]

        {
          'filePath' => file_path,
          'sourceCode' => raw && strip_annotate_header(raw),
          'live' => live
        }
      end

      # @param file_path [String, nil]
      # @return [Boolean]
      def readable?(file_path)
        !file_path.nil? && File.file?(file_path) && File.readable?(file_path)
      rescue StandardError
        false
      end

      # Remove a leading annotate schema block (`# == Schema Information` and
      # the comment lines that follow it, plus trailing blank lines). Blocks
      # appearing later in the file — or absent — leave the source unchanged.
      #
      # @param source [String]
      # @return [String]
      def strip_annotate_header(source)
        lines = source.lines
        start = lines.index { |line| line.match?(ANNOTATE_HEADER_RE) }
        return source unless start && leading_comment_region?(lines[0...start])

        finish = start
        finish += 1 while comment?(lines[finish + 1])
        finish += 1 while blank?(lines[finish + 1])

        (lines[0...start] + (lines[(finish + 1)..] || [])).join
      end

      # Whether every line before the annotate header is a comment or blank —
      # i.e. the header sits in the file's leading comment region.
      #
      # @param lines [Array<String>]
      # @return [Boolean]
      def leading_comment_region?(lines)
        lines.all? { |line| blank?(line) || comment?(line) }
      end

      # @return [Boolean]
      def comment?(line)
        !line.nil? && line.lstrip.start_with?('#')
      end

      # @return [Boolean]
      def blank?(line)
        !line.nil? && line.strip.empty?
      end
    end
  end
end
