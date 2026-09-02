# frozen_string_literal: true

module Woods
  module Extractors
    # Quote-aware line preprocessing shared by Woods' line-based parsers.
    #
    # Several extractors (and the chunkers' sibling heuristic) classify a line
    # by matching keywords against it: does it open a block, does it close one,
    # does it declare a constant. Run against raw source those matchers read
    # prose as code — `x.to_s # pad for display` opens a `for` block that
    # nothing closes, `title { "things to do" }` opens a `do` block, and
    # `module Api # rename at the end` looks self-terminated because the
    # comment ends in the word "end".
    #
    # This module centralizes the walker that removes those false signals. The
    # quote-aware comment stripper originated in
    # {SharedDependencyScanner#strip_line_comment}; the string-blanking and
    # heredoc-aware variants are the same walk with the literal bodies erased.
    #
    # Known limitations (deliberate — this is a scanner, not a parser):
    # `%`-literals (`%w[]`, `%q{}`), regular-expression literals, and character
    # literals whose char is a quote (`?'`) are not modeled. Mis-reading one
    # only risks an unstripped comment or an over-blanked line, never a crash.
    #
    # @example Neutralizing a line before a block-opener check
    #   LineNeutralizer.neutralize_line('title { "things to do" } # for now')
    #   # => "title { \"              \" } "
    #
    module LineNeutralizer
      # Start of a heredoc: `<<~SQL`, `<<-EOS`, `<<'RAW'`, `<<~"TEXT"`.
      # The bare (unquoted) form requires the identifier to follow `<<`
      # immediately and start uppercase, which is how Ruby itself
      # distinguishes `x <<HEREDOC` from the `<<` shift operator.
      HEREDOC_START = /<<[~-]?(?:(["'`])([A-Za-z_]\w*)\1|([A-Z_]\w*))/

      module_function

      # Strip a trailing `#` comment from a single line, ignoring `#`
      # characters inside string literals. Preserves the trailing newline.
      #
      # @param line [String]
      # @return [String]
      def strip_line_comment(line)
        walk(line, blank_strings: false).first
      end

      # Strip a trailing `#` comment AND blank the contents of string
      # literals, so keywords inside prose cannot be read as code. The
      # delimiters survive (`"…"` stays a string-shaped token); only the
      # bytes between them become spaces. Preserves the trailing newline.
      #
      # @param line [String]
      # @return [String]
      def neutralize_line(line)
        walk(line, blank_strings: true).first
      end

      # Remove `#` line comments from a whole source without touching `#`
      # characters inside string literals.
      #
      # @param source [String] Ruby source code
      # @return [String]
      def strip_comments(source)
        source.each_line.map { |line| strip_line_comment(line) }.join
      end

      # Neutralize a whole source line by line, additionally blanking heredoc
      # bodies (which a single-line walk cannot see). The result has exactly
      # as many lines as the input, so callers can index the two in lockstep:
      # match keywords against the neutralized line, read content from the
      # original.
      #
      # @param source [String] Ruby source code
      # @return [Array<String>] One neutralized line per input line
      def neutralize_lines(source)
        pending = []

        source.each_line.map do |line|
          if pending.any?
            pending.shift if heredoc_terminator?(line, pending.first)
            blank_line(line)
          else
            neutralized, heredocs = walk(line, blank_strings: true)
            pending.concat(heredocs)
            neutralized
          end
        end
      end

      # Walk one line tracking string state.
      #
      # @param line [String]
      # @param blank_strings [Boolean] Replace literal bodies with spaces
      # @return [Array(String, Array<String>)] Processed line and the heredoc
      #   identifiers the line opens
      def walk(line, blank_strings:)
        out = +''
        heredocs = []
        quote = nil
        index = 0
        length = line.length

        while index < length
          char = line[index]

          if quote
            if char == '\\'
              pair = line[index, 2].to_s
              out << (blank_strings ? blank(pair) : pair)
              index += 2
              next
            end

            quote = nil if char == quote
            out << (quote && blank_strings ? blank(char) : char)
          elsif char == '#'
            break
          elsif char == '<' && (heredoc = match_heredoc(line, index))
            heredocs << (heredoc[2] || heredoc[3])
            out << heredoc[0]
            index += heredoc[0].length
            next
          else
            quote = char if ['"', "'"].include?(char)
            out << char
          end

          index += 1
        end

        out << "\n" if index < length && line.end_with?("\n")
        [out, heredocs]
      end
      private_class_method :walk

      # Replace every character with a space, keeping newlines so a
      # neutralized line still ends where the original did.
      #
      # @param text [String]
      # @return [String]
      def blank(text)
        text.gsub(/[^\n]/, ' ')
      end
      private_class_method :blank

      # @param line [String]
      # @param index [Integer] Offset of the `<` character
      # @return [MatchData, nil] Heredoc opener anchored at +index+
      def match_heredoc(line, index)
        match = HEREDOC_START.match(line, index)
        match if match && match.begin(0) == index
      end
      private_class_method :match_heredoc

      # @param line [String]
      # @param identifier [String] Heredoc terminator being waited on
      # @return [Boolean]
      def heredoc_terminator?(line, identifier)
        line.strip == identifier
      end
      private_class_method :heredoc_terminator?

      # @param line [String]
      # @return [String] The line's newline, or an empty string
      def blank_line(line)
        line.end_with?("\n") ? "\n" : ''
      end
      private_class_method :blank_line
    end
  end
end
