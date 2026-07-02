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
    module SqlNoiseStripper
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
      # @param sql [String] the SQL string to process
      # @param dialect [Symbol] `:postgres` (default) or `:mysql` — controls
      #   single-quote escape rules (see {.strip_literals}).
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
            close = single_quote_end(sql, i, mysql: mysql)
            if close
              out << "''"
              i = close
            else
              # Unterminated literal — never under-detect; keep the char.
              out << ch
              i += 1
            end
          elsif ch == '$' && (tag = dollar_tag_at(sql, i))
            close = sql.index(tag, i + tag.length)
            if close
              out << "''"
              i = close + tag.length
            else
              out << ch
              i += 1
            end
          elsif ch == '-' && sql[i + 1] == '-'
            nl = sql.index("\n", i)
            i = nl || len
          elsif ch == '/' && sql[i + 1] == '*'
            close = sql.index('*/', i + 2)
            i = close ? close + 2 : len
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

      # Return the index just past the closing quote of the single-quoted
      # literal that opens at +start+, honoring `''` (both dialects) and `\'`
      # (MySQL only) escapes. Returns nil when the literal is unterminated.
      #
      # @api private
      def self.single_quote_end(sql, start, mysql:)
        i = start + 1
        len = sql.length
        while i < len
          c = sql[i]
          if mysql && c == '\\'
            i += 2
          elsif c == "'"
            return i + 1 unless sql[i + 1] == "'" # closing quote

            i += 2 # doubled-quote escape — literal continues
          else
            i += 1
          end
        end
        nil
      end
      private_class_method :single_quote_end
    end
  end
end
