# frozen_string_literal: true

# @see Woods
module Woods
  module Console
    # Strips SQL comments and string literals from a SQL string so that
    # downstream checks (keyword scanning, table scanning) are not confused
    # by content embedded inside comments or literals.
    #
    # This is a shared utility used by {SqlValidator} and {TableGate} to
    # avoid duplicating comment- and literal-stripping logic. All methods
    # are module-level and stateless — pass a SQL string in, receive a
    # stripped string out.
    #
    # @example Strip comments only
    #   SqlNoiseStripper.strip_comments("SELECT 1 -- pick one\nFROM t")
    #   # => "SELECT 1 \nFROM t"
    #
    # @example Strip literals (PostgreSQL dialect)
    #   SqlNoiseStripper.strip_literals("SELECT 'it''s ok' FROM t")
    #   # => "SELECT '' FROM t"
    #
    # @example Strip literals (MySQL dialect — backslash escapes)
    #   SqlNoiseStripper.strip_literals("SELECT 'it\\'s ok' FROM t", dialect: :mysql)
    #   # => "SELECT '' FROM t"
    #
    module SqlNoiseStripper # rubocop:disable Metrics/ModuleLength
      # Strips SQL line comments (`-- ...`) and block comments (`/* ... */`).
      # Line comments are stripped to (but not including) the newline so that
      # newline-separated statement structure is preserved for callers that
      # check for multiple statements.
      #
      # Block comments are non-nested — real SQL engines do not support nested
      # block comments, and neither does this stripper.
      #
      # @param sql [String] the SQL string to process
      # @return [String] a new string with all SQL comments removed
      LINE_COMMENT   = /--[^\n]*/
      BLOCK_COMMENT  = %r{/\*.*?\*/}m

      def self.strip_comments(sql)
        out = sql.gsub(LINE_COMMENT, '')
        out.gsub(BLOCK_COMMENT, '')
      end

      # Strips single-quoted string literals and (for the `:postgres` dialect)
      # PostgreSQL dollar-quoted string literals from a SQL string, replacing
      # each with an empty `''` placeholder so that the structure of the SQL
      # is maintained for subsequent checks.
      #
      # Dollar-quoted strings are stripped before single-quoted strings so that
      # stray apostrophes inside a dollar-quoted body do not confuse the
      # single-quote scanner.
      #
      # @param sql [String] the SQL string to process
      # @param dialect [Symbol] `:postgres` (default) or `:mysql`.
      #   - `:postgres` — single-quoted strings support `''` as an apostrophe
      #     escape. Backslash is treated literally and does not escape quotes.
      #     Dollar-quoted strings (`$$...$$`, `$tag$...$tag$`) are also stripped.
      #   - `:mysql` — single-quoted strings support both `\'` (backslash-escape)
      #     and `''` (doubled-quote) as apostrophe escapes. Dollar-quoted strings
      #     are also stripped (MySQL does not use them, but stripping them is
      #     harmless and keeps the two dialects consistent).
      # @return [String] a new string with all string literals replaced by `''`
      # @raise [ArgumentError] if an unsupported dialect is provided
      DOLLAR_QUOTED = /\$(\w*)\$.*?\$\1\$/m
      SINGLE_QUOTED_POSTGRES = /'(?:''|[^'])*'/m
      SINGLE_QUOTED_MYSQL    = /'(?:\\.|''|[^'])*'/m

      SUPPORTED_DIALECTS = %i[postgres mysql].freeze
      private_constant :SUPPORTED_DIALECTS

      def self.strip_literals(sql, dialect: :postgres)
        unless SUPPORTED_DIALECTS.include?(dialect)
          raise ArgumentError, "Unknown dialect #{dialect.inspect}. Supported: #{SUPPORTED_DIALECTS.inspect}"
        end

        # Strip dollar-quoted strings first so stray apostrophes inside them
        # do not interfere with the single-quote scanner.
        out = sql.gsub(DOLLAR_QUOTED, "''")

        pattern = dialect == :mysql ? SINGLE_QUOTED_MYSQL : SINGLE_QUOTED_POSTGRES
        out.gsub(pattern, "''")
      end

      # Strip BOTH comments and string literals in a single left-to-right
      # pass, so a comment marker inside a literal and a quote inside a
      # comment are each protected by whichever construct opens first.
      #
      # Running {.strip_comments} then {.strip_literals} (or vice versa) is
      # unsafe: `SELECT '-- ' FROM blocked` has its real `FROM blocked`
      # swallowed as a line comment (the `--` sits inside a string literal),
      # letting a blocked table slip past {TableGate}; the reverse order
      # mis-handles an apostrophe inside a `--` comment. Only a combined scan
      # that tracks literal/comment state correctly resolves both. This
      # scanner backs security checks (SqlValidator, TableGate) so it must
      # never under-detect: an unterminated literal is treated as an ordinary
      # character rather than swallowing the rest of the statement.
      #
      # `#` opens a MySQL line comment, mirroring `--`, but only under the
      # `:mysql` dialect — PostgreSQL does not treat `#` as a comment, and
      # collapsing it there would hide SQL that a real PostgreSQL server
      # still executes. A MySQL `/*! ... */` executable comment is left
      # untouched (not treated as a comment at all, under either dialect):
      # MySQL runs its body, so it must stay visible to every downstream
      # scan; leaving it visible under `:postgres` too is over-detection at
      # worst, never under-detection, on a server where it really is inert.
      # An ordinary `/* ... */` block comment is replaced by a single
      # newline rather than vanishing outright, mirroring how a `--`/`#`
      # line comment's own trailing newline survives: SqlValidator's
      # statement-leader scan needs a durable marker showing a comment sat
      # here so a comment-hidden statement (`SELECT 1 /*;*/ DELETE ...`)
      # still reads as following a boundary once comments are gone.
      #
      # @param sql [String] the SQL string to process
      # @param dialect [Symbol] `:postgres` (default) or `:mysql` — controls
      #   single-quote escape rules (see {.strip_literals}) and whether `#`
      #   opens a line comment.
      # @return [String] a new string with comments removed and every string
      #   literal replaced by `''`
      # @raise [ArgumentError] if an unsupported dialect is provided
      def self.strip_noise(sql, dialect: :postgres) # rubocop:disable Metrics/MethodLength,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
        unless SUPPORTED_DIALECTS.include?(dialect)
          raise ArgumentError, "Unknown dialect #{dialect.inspect}. Supported: #{SUPPORTED_DIALECTS.inspect}"
        end

        mysql = dialect == :mysql
        out = +''
        i = 0
        len = sql.length

        while i < len
          ch = sql[i]

          if ch == "'"
            close = single_quote_end(sql, i, backslash_escapes: mysql || postgres_escape_string?(sql, i))
            if close
              out << "''"
              i = close
            else
              # Unterminated literal — never under-detect; keep the char.
              out << ch
              i += 1
            end
          elsif ch == '"'
            close = quoted_span_end(sql, i, quote: '"', backslash_escapes: mysql)
            if close
              # MySQL parses double quotes as strings unless ANSI_QUOTES is
              # enabled. Treating them as literals prevents a `#` inside the
              # value from hiding live SQL. PostgreSQL uses them for
              # identifiers, which must remain visible to table/column scans.
              out << double_quote_replacement(sql, i, close, mysql: mysql)
              i = close
            else
              out << ch
              i += 1
            end
          elsif mysql && ch == '`'
            close = quoted_span_end(sql, i, quote: '`', backslash_escapes: true)
            if close
              # Backticks delimit identifiers. Preserve the token for table
              # and protected-column scans while shielding comment markers
              # inside it from the noise scanner.
              out << sql[i...close]
              i = close
            else
              out << ch
              i += 1
            end
          elsif ch == '$' && !preceded_by_word_char?(sql, i) && (tag = dollar_tag_at(sql, i))
            close = sql.index(tag, i + tag.length)
            if close
              out << "''"
              i = close + tag.length
            else
              out << ch
              i += 1
            end
          elsif (ch == '-' && sql[i + 1] == '-') || (mysql && ch == '#')
            nl = sql.index("\n", i)
            i = nl || len
          elsif ch == '/' && sql[i + 1] == '*' && sql[i + 2] != '!'
            close = sql.index('*/', i + 2)
            if close
              # Preserve a newline in place of the removed comment, mirroring
              # line comments (see class docs): callers that check for
              # statement structure (SqlValidator's statement-leader scan)
              # need a survivable marker showing a comment sat here, the
              # same way a `--`/`#` comment's own trailing newline does.
              out << "\n"
              i = close + 2
            else
              # Unterminated block comment: never under-detect. Leave it in
              # place (over-detection is safe; the old regex also required a
              # closing */ and left an unterminated /* untouched).
              out << ch
              i += 1
            end
          else
            out << ch
            i += 1
          end
        end

        out
      end

      # Regexp matching a PostgreSQL dollar-quote opening tag (`$$` or
      # `$tag$`) at the start of the given slice.
      DOLLAR_TAG = /\A\$\w*\$/
      private_constant :DOLLAR_TAG

      # Return the dollar-quote tag opening at +index+, or nil.
      #
      # @api private
      def self.dollar_tag_at(sql, index)
        m = DOLLAR_TAG.match(sql[index..])
        m && m[0]
      end
      private_class_method :dollar_tag_at

      # Whether the character immediately before +index+ is a word character
      # (`\w`). PostgreSQL allows `$` inside identifiers (`x$a$`), so a `$`
      # is only a candidate dollar-quote opener when it does NOT follow an
      # identifier character — otherwise `x$a$ FROM blocked, (SELECT 1 AS
      # z$a$)` gets misread as one dollar-quoted literal spanning the real
      # FROM clause.
      #
      # @api private
      def self.preceded_by_word_char?(sql, index)
        index.positive? && sql[index - 1].match?(/\w/)
      end
      private_class_method :preceded_by_word_char?

      # Return the index just past the closing quote of the single-quoted
      # literal that opens at +start+, honoring `''` (both dialects) and `\'`
      # (MySQL only) escapes. Returns nil when the literal is unterminated.
      #
      # @api private
      def self.single_quote_end(sql, start, backslash_escapes:)
        quoted_span_end(sql, start, quote: "'", backslash_escapes: backslash_escapes)
      end
      private_class_method :single_quote_end

      def self.double_quote_replacement(sql, start, close, mysql:)
        mysql ? "''" : sql[start...close]
      end
      private_class_method :double_quote_replacement

      # Return the index just past a quoted span. Doubled delimiters escape
      # themselves in every supported dialect; MySQL strings/identifiers and
      # PostgreSQL E-strings additionally honor backslash escapes.
      #
      # @api private
      def self.quoted_span_end(sql, start, quote:, backslash_escapes:)
        i = start + 1
        len = sql.length
        while i < len
          c = sql[i]
          if backslash_escapes && c == '\\'
            i += 2
          elsif c == quote
            return i + 1 unless sql[i + 1] == quote # closing delimiter

            i += 2 # doubled-delimiter escape — span continues
          else
            i += 1
          end
        end
        nil
      end
      private_class_method :quoted_span_end

      # PostgreSQL E'...' strings opt into C-style backslash escapes. The E
      # must begin a token; an identifier ending in e immediately before a
      # quote is not an escape-string prefix.
      #
      # @api private
      def self.postgres_escape_string?(sql, quote_index)
        return false unless quote_index.positive? && sql[quote_index - 1].match?(/[eE]/)

        quote_index < 2 || !sql[quote_index - 2].match?(/[A-Za-z0-9_$]/)
      end
      private_class_method :postgres_escape_string?
    end # rubocop:enable Metrics/ModuleLength
  end
end
