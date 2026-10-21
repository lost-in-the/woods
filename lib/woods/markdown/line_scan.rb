# frozen_string_literal: true

require 'strscan'

module Woods
  module Markdown
    # One line-based pass over a Markdown document: front matter, headings,
    # fenced and inline code, link targets and a word count.
    #
    # Not a CommonMark parser. Each line is classified once; every pattern is
    # anchored and possessive and inline scanning advances a byte cursor, so
    # the cost is linear in the document size whatever a line holds.
    #
    # @example
    #   scan = Woods::Markdown::LineScan.call("# Widgets\n\nSee `Widget`.\n")
    #   scan.headings # => [{ level: 1, text: "Widgets", line: 1 }]
    #   scan.code     # => [{ text: "Widget", line: 3, fence: false }]
    class LineScan # rubocop:disable Metrics/ClassLength
      # @!attribute front_matter
      #   @return [Array<Hash>] `{ key:, value:, line: }` per top-level scalar key
      # @!attribute front_matter_lines
      #   @return [Range, nil] 1-based lines of the front matter block
      # @!attribute headings
      #   @return [Array<Hash>] `{ level:, text:, line: }` in document order
      # @!attribute code
      #   @return [Array<Hash>] `{ text:, line:, fence: }` per inline span or fence body line
      # @!attribute links
      #   @return [Array<Hash>] `{ target:, line: }` per inline link or reference definition
      # @!attribute word_count
      #   @return [Integer] whitespace-separated words outside front matter
      # @!attribute line_count
      #   @return [Integer]
      Result = Struct.new(:front_matter, :front_matter_lines, :headings, :code, :links, :word_count, :line_count,
                          keyword_init: true)

      # `{n,m}+` is a repeated group in Ruby, not a possessive: atomic groups instead.
      FENCE_OPEN = /\A {0,3}((?>`{3,})|(?>~{3,}))/
      ATX_HEADING = /\A {0,3}((?>\#{1,6}))(?=[ \t]|\z)/
      SETEXT_UNDERLINE = /\A {0,3}(?:(=)++|-++)[ \t]*+\z/
      FRONT_MATTER_KEY = /\A([A-Za-z0-9_][A-Za-z0-9_.-]*+):(?=[ \t]|\z)/
      REFERENCE_DEFINITION = /\A {0,3}\[[^\]]*+\]:[ \t]*+(\S++)/
      BACKTICK_RUN = /`++/
      LINK_OPEN = /\]\(/
      LINK_PADDING = /[ \t]*+/
      ANGLE_TARGET = /<([^>]*+)>/
      BARE_TARGET = /[^\s)]*+/
      private_constant :FENCE_OPEN, :ATX_HEADING, :SETEXT_UNDERLINE, :FRONT_MATTER_KEY, :REFERENCE_DEFINITION,
                       :BACKTICK_RUN, :LINK_OPEN, :LINK_PADDING, :ANGLE_TARGET, :BARE_TARGET

      # @param source [String] Markdown text
      # @return [Result]
      def self.call(source)
        new(source).call
      end

      # @param source [String] Markdown text
      def initialize(source)
        @lines = source.to_s.dup.force_encoding(Encoding::UTF_8).scrub.split("\n", -1).map { |line| line.chomp("\r") }
        @lines.pop if @lines.last == ''
        @headings = []
        @code = []
        @links = []
        @front_matter = []
        @word_count = 0
      end

      # @return [Result]
      def call
        body_start = scan_front_matter
        @fence = nil
        @paragraph = nil
        (body_start...@lines.size).each { |index| scan_line(@lines[index], index + 1) }
        Result.new(front_matter: @front_matter, front_matter_lines: body_start.zero? ? nil : (1..body_start),
                   headings: @headings, code: @code, links: @links, word_count: @word_count,
                   line_count: @lines.size)
      end

      private

      # @return [Integer] index of the first body line
      def scan_front_matter
        return 0 unless @lines.first&.rstrip == '---'

        closing = (1...@lines.size).find { |index| ['---', '...'].include?(@lines[index].rstrip) }
        return 0 unless closing

        (1...closing).each { |index| record_front_matter_key(@lines[index], index + 1) }
        closing + 1
      end

      def record_front_matter_key(line, number)
        match = FRONT_MATTER_KEY.match(line)
        return unless match

        value = line.byteslice(match.end(0)..).to_s.strip
        value = value[1..-2] if value.size >= 2 && %w[" '].include?(value[0]) && value[-1] == value[0]
        @front_matter << { key: match[1], value: value, line: number }
      end

      def scan_line(line, number)
        @word_count += line.split.size
        return scan_fence_line(line, number) if @fence
        return if opens_fence?(line)

        heading = atx_heading(line, number) || setext_heading(line, number)
        @paragraph = heading || line.strip.empty? ? nil : [line.strip, number]
        @headings << heading if heading
        scan_inline_code(line, number)
        scan_links(line, number)
      end

      def scan_fence_line(line, number)
        if closes_fence?(line)
          @fence = nil
        else
          @code << { text: line.strip, line: number, fence: true } unless line.strip.empty?
        end
      end

      def opens_fence?(line)
        marker = line[FENCE_OPEN, 1]
        return false unless marker
        return false if marker.start_with?('`') && after_marker(line, marker).include?('`')

        @paragraph = nil
        @fence = marker
        true
      end

      def closes_fence?(line)
        marker = line[FENCE_OPEN, 1]
        return false unless marker && marker[0] == @fence[0] && marker.size >= @fence.size

        after_marker(line, marker).strip.empty?
      end

      def after_marker(line, marker)
        line.byteslice((line.index(marker) + marker.bytesize)..)
      end

      def atx_heading(line, number)
        match = ATX_HEADING.match(line)
        return nil unless match

        { level: match[1].size, text: strip_closing_hashes(line.byteslice(match.end(0)..).to_s.strip), line: number }
      end

      # Drops an ATX closing sequence (` ##`) with a byte walk: a regex anchored
      # at the end would rescan a long run of hashes from every start.
      def strip_closing_hashes(text)
        cut = text.bytesize
        cut -= 1 while cut.positive? && text.getbyte(cut - 1) == 35
        return text if cut == text.bytesize
        return '' if cut.zero?
        return text unless [32, 9].include?(text.getbyte(cut - 1))

        text.byteslice(0, cut).rstrip
      end

      def setext_heading(line, _number)
        match = SETEXT_UNDERLINE.match(line)
        return nil unless match && @paragraph

        { level: match[1] ? 1 : 2, text: @paragraph[0], line: @paragraph[1] }
      end

      # Pairs each backtick run with the next run of the same length. The
      # successor table is built right to left, so an unmatched run costs
      # nothing extra.
      def scan_inline_code(line, number)
        return unless line.include?('`')

        runs = backtick_runs(line)
        successors = same_length_successors(runs)
        index = 0
        while index < runs.size
          closer = successors[index]
          if closer
            start = runs[index][0] + runs[index][1]
            text = line.byteslice(start, runs[closer][0] - start).strip
            @code << { text: text, line: number, fence: false } unless text.empty?
            index = closer + 1
          else
            index += 1
          end
        end
      end

      # @return [Array<Array(Integer, Integer)>] byte offset and length per run
      def backtick_runs(line)
        scanner = StringScanner.new(line)
        runs = []
        runs << [scanner.pos - scanner.matched_size, scanner.matched_size] while scanner.skip_until(BACKTICK_RUN)
        runs
      end

      def same_length_successors(runs)
        latest = {}
        successors = Array.new(runs.size)
        (runs.size - 1).downto(0) do |index|
          successors[index] = latest[runs[index][1]]
          latest[runs[index][1]] = index
        end
        successors
      end

      def scan_links(line, number)
        reference = line[REFERENCE_DEFINITION, 1]
        return record_link(reference.delete_prefix('<').delete_suffix('>'), number) if reference
        return unless line.include?('](')

        scanner = StringScanner.new(line)
        while scanner.skip_until(LINK_OPEN)
          scanner.skip(LINK_PADDING)
          target = scanner.scan(ANGLE_TARGET) ? scanner[1] : scanner.scan(BARE_TARGET)
          record_link(target, number)
        end
      end

      def record_link(target, number)
        @links << { target: target, line: number } unless target.nil? || target.empty?
      end
    end
  end
end
