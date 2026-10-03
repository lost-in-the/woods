# frozen_string_literal: true

require 'set'
require 'strscan'

module Woods
  module Extractors
    # Finds calls to application helper methods in Ruby source.
    #
    # Rails mixes every helper module into every view, so a template calls
    # `pretty_date(x)` without naming `DateHelper`. {.method_calls} is the
    # scan half of closing that gap: one token pass over a source against a
    # Set of catalog names. Each token is read once, and every pattern is
    # anchored at the scanner position, so the pass is linear in the source.
    #
    # The pass is lexical, not a parse. It reports a name when it appears as
    # a receiverless call, or as a call on the `helpers` proxy. It skips a
    # name used as a symbol, a hash label, a method called on another
    # receiver, a method definition, string text, a comment, or a local
    # (an assignment target, a block parameter, a `local_assigns` or
    # `defined?` probe, or a local the caller names).
    class HelperCallScan
      # A plain identifier, with a trailing `?` or `!` unless that
      # character starts `!=` or `?=`.
      IDENTIFIER = /[A-Za-z_]\w*+(?:[?!](?!=))?/

      SPACE = /\s++/
      COMMENT = /#[^\n]*+/
      SINGLE_QUOTED = /'(?:[^'\\]++|\\.)*+'/m
      WORD_ARRAY_OPEN = /%[wWiI][\[({]/
      WORD_ARRAY = /%[wWiI](?:\[[^\]]*+\]|\([^)]*+\)|\{[^}]*+\})/
      # Tokens that are never a call and never a receiver: a range operator,
      # a symbol, an instance/class/global variable, a number.
      INERT = /\.{2,3}|:[A-Za-z_]\w*+[?!=]?+|@@?+[A-Za-z_]\w*+|\$\w++|\d\w*+(?:\.\d\w*+)?/
      SCOPE = /::/
      DOT = /&?\./
      # A `name:` label: one colon, not `::`.
      LABEL = /:(?!:)/
      # `=` and operator-assignment, but not `==`, `=~`, or `=>`.
      ASSIGNMENT = %r{[ \t]*+(?:\|\||&&|[-+*/%])?=(?![=~>])}
      BLOCK_PARAMETERS = /\|([^|\n]*+)\|/
      LOCAL_ASSIGNS_KEY = /(?:\[|\.(?:fetch|key\?|dig)\(?)\s*+:([A-Za-z_]\w*+)/
      DEFINED_OPERAND = /\s*+\(?\s*+([a-z_]\w*+)/
      INTERPOLATION = /#\{/
      ESCAPE = /\\./m
      # Text of an interpolating literal up to the next character that can
      # end it, escape it, or open an interpolation.
      STRING_TEXT = { '"' => /[^"\\#]++/, '`' => /[^`\\#]++/ }.freeze

      # The view-context proxy controllers and components call helpers on.
      HELPERS_PROXY = 'helpers'

      class << self
        # @param code [String] Ruby source (for a template: its Ruby regions)
        # @param names [Set<String>] catalog method names to look for
        # @param locals [Enumerable<String>] names known to be locals
        # @return [Hash{Symbol => Array<String>}] `{ bare:, explicit: }`,
        #   each sorted: receiverless calls and `helpers.` calls
        def method_calls(code, names, locals: [])
          new(code, names, locals).method_calls
        end
      end

      # @param code [String]
      # @param names [Set<String>]
      # @param locals [Enumerable<String>]
      def initialize(code, names, locals)
        @scanner = StringScanner.new(code.valid_encoding? ? code : code.scrub(' '))
        @names = names
        @locals = locals.to_set
        @bare = Set.new
        @explicit = Set.new
        # Open literals, innermost last. A String frame is the terminator of
        # an interpolating literal; an Integer frame is the brace depth of
        # the code inside one of its interpolations (or of the source itself).
        @frames = [0]
        @previous = nil
      end

      # @return [Hash{Symbol => Array<String>}]
      def method_calls
        @frames.last.is_a?(String) ? scan_string_text : scan_code until @scanner.eos?
        { bare: (@bare - @locals).sort, explicit: @explicit.sort }
      end

      private

      def scan_code
        return if @scanner.skip(SPACE) || @scanner.skip(COMMENT)

        previous = @previous
        @previous = nil
        if (word = @scanner.scan(IDENTIFIER)) then identifier(word, previous)
        elsif @scanner.skip(INERT) then nil
        elsif @scanner.skip(DOT) then @previous = previous == HELPERS_PROXY ? :helpers_dot : :dot
        elsif @scanner.skip(SCOPE) then @previous = :dot
        else punctuation(previous)
        end
      end

      def identifier(word, previous)
        return if previous == :def
        return @previous = :def if word == 'def'
        return @previous = :block_open if word == 'do'
        return @explicit << word if previous == :helpers_dot && @names.include?(word)
        return @previous = word if previous == :dot
        return if @scanner.match?(LABEL)
        return @locals << word if @scanner.match?(ASSIGNMENT)

        probe_locals(word)
        @previous = word
        @bare << word if @names.include?(word)
      end

      def probe_locals(word)
        pattern = { 'local_assigns' => LOCAL_ASSIGNS_KEY, 'defined?' => DEFINED_OPERAND }[word]
        @locals << @scanner[1] if pattern && @scanner.scan(pattern)
      end

      def punctuation(previous)
        case @scanner.peek(1)
        when "'" then quoted(SINGLE_QUOTED)
        when '%' then @scanner.match?(WORD_ARRAY_OPEN) ? quoted(WORD_ARRAY) : @scanner.getch
        when '"', '`' then @frames << @scanner.getch
        when '{' then open_brace
        when '}' then close_brace
        when '|' then block_parameters(previous)
        else @scanner.getch
        end
      end

      # Skip a non-interpolating literal. One left open runs to the end of
      # the source, so the scan ends there rather than retrying the same
      # search from every later quote.
      def quoted(pattern)
        @scanner.skip(pattern) || @scanner.terminate
      end

      def open_brace
        @scanner.getch
        @frames[-1] += 1
        @previous = :block_open
      end

      def close_brace
        @scanner.getch
        if @frames.last.zero?
          @frames.pop if @frames.size > 1
        else
          @frames[-1] -= 1
        end
      end

      def block_parameters(previous)
        return @scanner.getch unless previous == :block_open && @scanner.skip(BLOCK_PARAMETERS)

        @scanner[1].scan(IDENTIFIER) { |name| @locals << name }
      end

      def scan_string_text
        terminator = @frames.last
        if @scanner.skip(STRING_TEXT.fetch(terminator)) || @scanner.skip(ESCAPE) then nil
        elsif @scanner.skip(INTERPOLATION) then @frames << 0
        elsif @scanner.getch == terminator then @frames.pop
        end
      end
    end
  end
end
