# frozen_string_literal: true

require 'strscan'

module Woods
  module Extractors
    # A shallow, linear JavaScript/TypeScript tokenizer.
    #
    # It exists so the `js_module` scanners never read a comment or the inside
    # of a string as code. It is not a parser: it knows identifiers, string and
    # template literals, regular-expression literals, numbers and punctuation.
    # Every pattern consumes at least one byte and never backtracks over what
    # another pattern could match, so a pass is linear in the source size.
    #
    # Tokens are +[type, value]+ pairs:
    #
    # * +[:ident, "name"]+
    # * +[:string, "contents"]+ for quoted strings and interpolation-free templates
    # * +[:template, nil]+ for each literal part of an interpolated template
    # * +[:number, nil]+ and +[:regex, nil]+ (a value was here; its text is dropped)
    # * +[:punct, "="]+ (+=>+, +==+, +===+ and +...+ stay whole)
    #
    # @example
    #   JsTokenizer.tokens('import Widget from "./widget"')
    #   # => [[:ident, "import"], [:ident, "Widget"], [:ident, "from"], [:string, "./widget"]]
    class JsTokenizer
      WHITESPACE = /\s+/
      LINE_COMMENT = %r{//[^\n]*+}
      BLOCK_COMMENT_OPEN = %r{/\*}
      BLOCK_COMMENT_CLOSE = %r{\*/}
      IDENTIFIER = /[A-Za-z_$][A-Za-z0-9_$]*+/
      NUMBER = /[0-9][A-Za-z0-9_.]*+/
      DOUBLE_QUOTED = /"((?:[^"\\\n]++|\\.)*+)"?/m
      SINGLE_QUOTED = /'((?:[^'\\\n]++|\\.)*+)'?/m
      TEMPLATE_PART = /(?:[^`\\$]++|\\.|\$(?!\{))*+/m
      # One line only, so a stray slash cannot swallow the rest of a file.
      REGEX_LITERAL = %r{\A/(?:[^/\\\[\n]++|\\[^\n]|\[(?:[^\]\\\n]++|\\[^\n])*+\])++/[A-Za-z]*+}
      PUNCTUATION = /=>|={1,3}|\.\.\.|[\x21-\x7E]/
      NON_ASCII = /[^\x00-\x7F]++/
      # A regular expression literal is looked for within this many bytes.
      # After a failed attempt no other is made inside the same window, so
      # the attempts on one file cost at most its size.
      REGEX_WINDOW = 2_000

      # A slash after one of these starts a regular expression, not a division.
      REGEX_PRECEDING_KEYWORDS = %w[return typeof case in of delete void throw new else do yield await instanceof].freeze
      VALUE_ENDING_PUNCTUATION = [')', ']', '}'].freeze

      # What a token starting with each byte is, so a step tries one pattern.
      BYTE_CLASSES = Array.new(256) do |byte|
        case byte
        when 65..90, 97..122, 95, 36 then :word
        when 48..57 then :digit
        when 47 then :slash
        when 34, 39 then :quote
        when 96 then :backtick
        when 128..255 then :high
        else :other
        end
      end.freeze

      # @param source [String] file contents
      # @return [Array<Array(Symbol, String)>] tokens in source order
      def self.tokens(source)
        new(source).tokens
      end

      # @param source [String] file contents
      def initialize(source)
        text = source.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text = text.scrub('?') unless text.valid_encoding?
        @text = text
        @scanner = StringScanner.new(text)
        @tokens = []
        # Open template interpolations, each the brace depth inside its `${`.
        @interpolations = []
        @regex_resume_at = 0
      end

      # @return [Array<Array(Symbol, String)>]
      def tokens
        step until @scanner.eos?
        @tokens
      end

      private

      def step
        @scanner.skip(WHITESPACE)
        case BYTE_CLASSES[@text.getbyte(@scanner.pos) || 0]
        when :word then emit(:ident, @scanner.scan(IDENTIFIER))
        when :digit then @scanner.skip(NUMBER) && emit(:number, nil)
        when :slash then skip_comment || scan_regex || scan_punctuation
        when :quote then scan_quoted
        when :backtick then scan_template_open
        when :high then @scanner.skip(NON_ASCII)
        else scan_punctuation unless @scanner.eos?
        end
      end

      def skip_comment
        return true if @scanner.skip(LINE_COMMENT)
        return false unless @scanner.skip(BLOCK_COMMENT_OPEN)

        @scanner.skip_until(BLOCK_COMMENT_CLOSE) || @scanner.terminate
        true
      end

      def scan_quoted
        emit(:string, @scanner[1]) if @scanner.skip(DOUBLE_QUOTED) || @scanner.skip(SINGLE_QUOTED)
      end

      def scan_template_open
        @scanner.pos += 1
        scan_template_part(first: true)
      end

      # Reads literal template text up to the closing backtick or the next
      # `${`. An interpolation is tokenized as ordinary code; its closing
      # brace returns here.
      def scan_template_part(first: false)
        text = @scanner.scan(TEMPLATE_PART)
        if @scanner.skip(/\$\{/)
          emit(:template, nil)
          @interpolations.push(0)
        elsif @scanner.skip(/`/) || @scanner.eos?
          first ? emit(:string, text) : emit(:template, nil)
        end
      end

      def scan_regex
        return false unless @scanner.pos >= @regex_resume_at && regex_allowed?

        literal = @scanner.peek(REGEX_WINDOW).scrub('?')[REGEX_LITERAL]
        if literal.nil? || literal.bytesize >= REGEX_WINDOW
          @regex_resume_at = @scanner.pos + REGEX_WINDOW
          return false
        end

        @scanner.pos += literal.bytesize
        emit(:regex, nil)
        true
      end

      def regex_allowed?
        type, value = @tokens.last
        case type
        when nil then true
        when :punct then !VALUE_ENDING_PUNCTUATION.include?(value)
        when :ident then REGEX_PRECEDING_KEYWORDS.include?(value)
        else false
        end
      end

      def scan_punctuation
        value = @scanner.scan(PUNCTUATION)
        return @scanner.getch if value.nil?
        return if closes_interpolation?(value)

        @interpolations[-1] += 1 if value == '{' && @interpolations.any?
        emit(:punct, value)
      end

      def closes_interpolation?(value)
        return false unless value == '}' && @interpolations.any?
        return (@interpolations[-1] -= 1) && false if @interpolations.last.positive?

        @interpolations.pop
        scan_template_part
        true
      end

      def emit(type, value)
        @tokens << [type, value]
      end
    end
  end
end
