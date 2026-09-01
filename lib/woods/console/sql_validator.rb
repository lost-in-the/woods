# frozen_string_literal: true

require 'woods/console/sql_noise_stripper'

# @see Woods
module Woods
  class Error < StandardError; end unless defined?(Woods::Error)

  module Console
    class SqlValidationError < Woods::Error; end

    # Validates SQL strings for read-only safety.
    #
    # Allows only SELECT and WITH...SELECT statements. Rejects DML (INSERT,
    # UPDATE, DELETE), DDL (CREATE, DROP, ALTER, TRUNCATE), and administrative
    # commands (GRANT, REVOKE). Also rejects multiple statements (semicolons).
    #
    # Uses pattern-based validation, not full SQL parsing.
    #
    # @example
    #   validator = SqlValidator.new
    #   validator.validate!('SELECT * FROM users')         # passes
    #   validator.validate!('DELETE FROM users')            # raises SqlValidationError
    #   validator.valid?('SELECT 1')                       # => true
    #
    # Metrics/ClassLength is disabled here for the same reason as tool_specs.rb:
    # most of the length is declarative allowlist/denylist data (documented
    # named constants), not imperative logic.
    class SqlValidator # rubocop:disable Metrics/ClassLength
      # SQL dialects whose normalization the lock-clause check can run over.
      KNOWN_DIALECTS = %i[postgres mysql].freeze

      # The dialect the statement will execute under, when the caller knows
      # it. `nil` (the default) keeps the conservative union: every check
      # runs against both dialect normalizations, which can reject a
      # statement that is valid under one dialect's quote grammar (a MySQL
      # `\'` escape hides prose that the PostgreSQL view reads as SQL). When
      # the execution boundary knows the adapter, passing the matching
      # dialect validates the statement the way the server will actually
      # parse it. Every known bypass form stays rejected under every
      # dialect: the executable-comment views in {#lock_clause_views} cover
      # `#` comment splits and `/*!...*/` splits under both semantics.
      #
      # @return [Symbol, nil]
      attr_reader :dialect

      def initialize(dialect: nil)
        unless dialect.nil? || KNOWN_DIALECTS.include?(dialect)
          raise ArgumentError, "Unknown dialect #{dialect.inspect}. Supported: #{KNOWN_DIALECTS.inspect}"
        end

        @dialect = dialect
      end
      # Row-lock clauses that would take live row locks even under the
      # rolled-back SafeContext transaction (M5).
      #
      # `SELECT ... FOR UPDATE` and friends hold row locks for the duration
      # of the wrapping transaction — on both PostgreSQL (`FOR UPDATE`,
      # `FOR NO KEY UPDATE`, `FOR SHARE`, `FOR KEY SHARE`, with optional
      # `NOWAIT`/`SKIP LOCKED`) and MySQL (`FOR UPDATE` with the same
      # modifiers, plus `LOCK IN SHARE MODE`). While SafeContext rolls the
      # transaction back, the locks themselves are held live against other
      # writers for the whole request — a denial-of-service lever, not a
      # read. A dedicated check (rather than growing BODY_FORBIDDEN_KEYWORDS)
      # because these are multi-word trailing clauses: the body-keyword scan
      # is single-token and leader-anchored, neither of which can express
      # "FOR immediately followed by an update/share keyword".
      #
      # Scanned against the noise-stripped SQL (comments and string literals
      # removed), so prose like `WHERE note = 'waiting for update'` cannot
      # fire it. Over-detection on a pathologically quoted identifier such
      # as `"for update"` is accepted: conservative rejection is the
      # validator's documented posture.
      LOCK_CLAUSE_PATTERN = /
        \bFOR\s+(?:NO\s+KEY\s+UPDATE|UPDATE|KEY\s+SHARE|SHARE)\b
        |\bLOCK\s+IN\s+SHARE\s+MODE\b
      /xi

      # Matches an `AS (` opening whose balanced body {#check_writable_ctes!}
      # inspects. Kept loose on purpose: deciding which `AS (` shapes are
      # CTEs needs a real parser, and every non-CTE match (a WINDOW
      # definition, a nested WITH) is only rejected when its body starts
      # with DML, which is never valid in an allowed statement.
      AS_BODY_PATTERN = /\bAS\s*\(/i

      # A CTE (or any `AS (...)`) body that opens with a DML keyword —
      # the writable-CTE shape, in any WITH position. A single leading
      # `(` is tolerated: PostgreSQL rejects `WITH a AS ((DELETE ...))`
      # outright, so this is over-detection on a syntax that never runs,
      # not under-detection.
      WRITABLE_CTE_BODY_PATTERN = /\A\s*\(?\s*(?:DELETE|UPDATE|INSERT)\b/i

      # Matches a CTE list attached to a top-level data-modifying statement:
      # `WITH a AS (SELECT 1) DELETE FROM users RETURNING *`. Legal grammar
      # on PostgreSQL; the statement prefix is `WITH`, so the allowed-prefix
      # check passes it, and DELETE/UPDATE have no body keyword for the
      # body scans to catch (INSERT only tripped INTO, MERGE nothing).
      #
      # The lazy `[\s\S]*?` reaches the first closing paren that is
      # immediately followed by a DML keyword. In an allowed statement
      # that position is grammatically impossible: after a CTE list's
      # final `)` only SELECT (or another WITH) is valid, and a DML word
      # anywhere else is separated from the paren by other tokens or sits
      # inside a string literal, which {SqlNoiseStripper.strip_noise}
      # removed. Column names like `updated_at`/`deleted_at` cannot match:
      # `\b` requires the keyword to start right after the paren, and a
      # bare `update` column follows a comma or SELECT, not a paren.
      WITH_ATTACHED_DML_PATTERN = /\bWITH\b[\s\S]*?\)\s*(?:DELETE|UPDATE|INSERT|MERGE)\b/i

      # Matches a MySQL executable comment (`/*!...*/` or the version-guarded
      # `/*!NNNNN...*/`), capturing the body. Only scanned by
      # {#lock_clause_views} — {SqlNoiseStripper} deliberately leaves these
      # markers in place because their meaning is version-dependent.
      EXECUTABLE_COMMENT_PATTERN = %r{/\*!(?:\d{5})?(.*?)\*/}m

      # Forbidden statement prefixes (case-insensitive).
      #
      # Expanded beyond DML/DDL to cover:
      # - PG procedural (`DO`, `CALL`) which can run arbitrary plpgsql.
      # - Session-state mutation (`SET`, `RESET`) — `SET ROLE`, `SET search_path`
      #   can swap out the effective permission set for the rest of the session
      #   even under rollback.
      # - Admin/cluster ops (`VACUUM`, `ANALYZE`, `CLUSTER`, `REINDEX`,
      #   `REFRESH`, `LOCK`) which are reads in the English-language sense
      #   but carry side effects or heavy locks.
      # - Async signalling (`LISTEN`, `NOTIFY`).
      # - Prepared-statement lifecycle (`PREPARE`, `EXECUTE`, `DEALLOCATE`).
      # - Transaction control (`BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`,
      #   `RELEASE`, `START`) — SafeContext already owns the surrounding
      #   transaction; inner tx control would corrupt it.
      # - File I/O vectors (`LOAD`, `HANDLER`, `COPY`).
      # - Write vector (`MERGE`) — an upsert statement that can INSERT/UPDATE/
      #   DELETE depending on match, on databases that support it. Already
      #   caught by the allowed-prefix check (it isn't SELECT/WITH/EXPLAIN),
      #   but listed here too for defense in depth against a body-scan bypass.
      FORBIDDEN_KEYWORDS = %w[
        INSERT UPDATE DELETE MERGE DROP ALTER TRUNCATE CREATE GRANT REVOKE
        DO CALL SET RESET LISTEN NOTIFY
        VACUUM ANALYZE CLUSTER REINDEX REFRESH LOCK
        PREPARE EXECUTE DEALLOCATE
        BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE START
        LOAD HANDLER COPY
      ].freeze

      # Keywords that are forbidden anywhere in the SQL (not just at start).
      #
      # UNION / INTERSECT / EXCEPT are SQL set operators — any of them can graft
      # a second SELECT onto a validated one, which defeats the "single SELECT"
      # posture even though TableGate still catches references to blocked tables.
      # INTO / COPY are PostgreSQL write vectors that must not appear in read
      # contexts.
      BODY_FORBIDDEN_KEYWORDS = %w[UNION INTERSECT EXCEPT INTO COPY].freeze

      # Dangerous functions that can be used for DoS or file access.
      DANGEROUS_FUNCTIONS = %w[
        pg_sleep lo_import lo_export pg_read_file pg_write_file
        load_file sleep benchmark
      ].freeze

      # Enforceable read-only function policy for `console_sql`.
      #
      # The previous control was a denylist (DANGEROUS_FUNCTIONS above), which
      # is provably incomplete: PostgreSQL ships side-effecting functions that
      # are technically legal inside a SELECT list, e.g. `pg_terminate_backend`
      # (kills another backend), `pg_advisory_lock`/`pg_advisory_unlock`
      # (session-held locks that outlive the rolled-back transaction),
      # `nextval`/`setval` (permanently mutate a sequence, DDL rollback does
      # not undo it). Enumerating every such function is a losing race.
      #
      # Instead, `console_sql` allowlists a conservative set of pure/read
      # functions and rejects everything else with a typed error naming the
      # function. This is the authoritative, documented policy: extend it
      # deliberately, not by discovering a false positive and reaching for
      # DANGEROUS_FUNCTIONS instead.
      # Read-only functions supported across all three backends Woods claims
      # (MySQL, PostgreSQL, SQLite). Aggregates, window functions, and pure
      # scalar string/number/date/JSON readers only — nothing that mutates
      # state, sleeps, or reaches outside the query. Kept backend-agnostic on
      # purpose: a PG-only list rejected ordinary MySQL/SQLite analytics.
      ALLOWED_FUNCTIONS = %w[
        count sum avg min max coalesce nullif
        group_concat string_agg array_agg
        row_number rank dense_rank percent_rank cume_dist ntile
        lag lead first_value last_value nth_value
        lower upper length char_length character_length octet_length
        substr substring trim ltrim rtrim btrim concat concat_ws
        left right replace reverse repeat lpad rpad
        position strpos split_part
        abs round ceil ceiling floor mod power pow sqrt sign greatest least
        cast convert
        extract date_part date_trunc to_char to_date to_timestamp
        strftime datetime date time julianday unixepoch
        now current_date current_time current_timestamp
        json_extract json_value json_type json_array_length
        json_extract_path json_extract_path_text
        jsonb_extract_path jsonb_extract_path_text
      ].freeze

      # SQL keywords that are legitimately followed by `(` but are not
      # function calls: a subquery predicate (`IN (SELECT ...)`), a
      # parenthesized boolean group (`WHERE (a AND b)`), etc. Excluded from
      # the function-allowlist scan so they are not misclassified as unknown
      # function calls.
      FUNCTION_SCAN_EXCLUDED_KEYWORDS = %w[
        IN EXISTS NOT AND OR VALUES WHERE HAVING ON IS BETWEEN CASE WHEN
        THEN ELSE END FROM JOIN USING WITH SELECT DISTINCT ALL ANY SOME
        UNION INTERSECT EXCEPT ORDER GROUP BY ASC DESC LIMIT OFFSET AS INTO
        OVER PARTITION FILTER WITHIN RETURNING EXPLAIN
      ].freeze

      # EXPLAIN is a statement leader, so `EXPLAIN (FORMAT JSON) SELECT` is an
      # option list, not a call; ALLOWED_PREFIXES already refuses ANALYZE inside
      # that list (B-125).
      # Matches a function-call shape: an identifier immediately followed by
      # `(`, where the identifier may be bare, double-quoted (ANSI/PostgreSQL),
      # or backtick-quoted (MySQL). Quoting the name was the bypass — a bare
      # `\bword\(` pattern never fired on `"pg_terminate_backend"(`, so a
      # side-effecting function wrapped in quotes defeated both the allowlist
      # and the legacy denylist. Runs against the noise-stripped SQL (comments
      # and string literals removed) so literal content can't be misread.
      FUNCTION_CALL_PATTERN = /(?:"([^"]+)"|`([^`]+)`|\b([A-Za-z_][A-Za-z0-9_]*))\s*\(/

      # Allowed statement prefixes (case-insensitive).
      #
      # `EXPLAIN ANALYZE` actually executes the planned query on PostgreSQL
      # (and the MySQL 8.0+ `EXPLAIN ANALYZE` does the same) — explicitly
      # reject the `ANALYZE` variant, and PostgreSQL's `ANALYSE` spelling
      # alias for it (both are accepted by the server; rejecting only one
      # left the other as a bypass). PostgreSQL also accepts an option-list
      # form `EXPLAIN (ANALYZE, FORMAT JSON) SELECT …` where `ANALYZE` follows
      # `(` rather than whitespace; the `(?!\s*\(?\s*ANALY[SZ]E)` lookahead
      # rejects both spellings in both positions so SafeContext doesn't
      # silently trust "we're just planning, not running" for what is a
      # side-effectful execution. `EXPLAIN (…)` without `ANALYZE`/`ANALYSE`
      # is still permitted (e.g. `EXPLAIN (FORMAT JSON) SELECT 1`).
      ALLOWED_PREFIXES = /\A\s*(SELECT|WITH|EXPLAIN(?!\s+ANALY[SZ]E)(?!\s*\([^)]*\bANALY[SZ]E\b))\b/i

      # Frozen map of forbidden keyword => regex matching the keyword at statement start.
      # Used by {#check_forbidden_keywords!} and {#check_forbidden_keywords_in_body!}.
      FORBIDDEN_PREFIX_REGEXES = FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /\A\s*#{kw}\b/i]
      end.freeze

      # Frozen map of forbidden body keyword => regex matching the keyword anywhere.
      # Used by {#check_body_forbidden_keywords!}.
      BODY_FORBIDDEN_REGEXES = BODY_FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /\b#{kw}\b/i]
      end.freeze

      # Frozen map of forbidden keyword => regex matching the keyword as a
      # statement leader: at the very start of the SQL, or immediately after
      # a `;` or a newline. Used by {#check_forbidden_keywords_in_body!}.
      #
      # A live `;` never reaches this check unescaped — #validate! rejects
      # multiple statements earlier — so a `;` match here only ever comes
      # from inside a comment that {SqlNoiseStripper} stripped. The same is
      # true of the newline: every comment flavor (`--`, `#`, `/* ... */`)
      # leaves one behind in place of its own content specifically so a
      # comment-hidden statement (`SELECT 1 --;\nDELETE FROM users`,
      # `SELECT 1 /*;*/ DELETE FROM users`) still reads as following a
      # boundary once the comment is gone.
      #
      # Matching anywhere (the previous behavior) rejected a column
      # legitimately named after a forbidden keyword — `WHERE do = 1`,
      # `release`, `lock`, `handler` are all plausible column names, none of
      # them a statement. Anchoring to leader positions is what tells the
      # two apart.
      FORBIDDEN_BODY_REGEXES = FORBIDDEN_KEYWORDS.to_h do |kw|
        [kw, /(?:\A|[;\n])\s*#{kw}\b/i]
      end.freeze

      # DML keywords that are additionally forbidden as bare tokens ANYWHERE
      # in the statement body, not just at statement-leader positions.
      #
      # {FORBIDDEN_BODY_REGEXES} stays leader-anchored for the full
      # {FORBIDDEN_KEYWORDS} set because words like `do`, `lock`, `release`,
      # `handler` are plausible bare column names (`WHERE do = 1` is a read,
      # not a write). INSERT, UPDATE, and DELETE cannot hide behind that
      # argument: they are reserved words on every supported backend, so a
      # bare occurrence inside an allowed statement is never an identifier —
      # it is a mid-body write (e.g. `SELECT 1 UPDATE posts SET status = 10`)
      # that used to pass validation and fail as an adapter-level syntax
      # error instead of a typed refusal at this boundary.
      #
      # MERGE is deliberately NOT in this set: SQLite permits an unquoted
      # `merge` column, so body-level MERGE scanning would false-positive on
      # ordinary selects like `SELECT merge FROM posts`. MERGE statements
      # stay covered where they are actually statements: the allowed-prefix
      # rule (MERGE is in {FORBIDDEN_KEYWORDS}, checked at statement start)
      # and {WITH_ATTACHED_DML_PATTERN} for the WITH-attached shape.
      #
      # Scanned against the noise-stripped SQL ({SqlNoiseStripper}), so
      # literal content never triggers (`SELECT 'update' AS word` is a
      # value, not a write), and `\b` keeps identifier-shaped column names
      # (`updated_at`, `last_update`) accepted. Multi-word lock clauses
      # (`FOR UPDATE`) keep their dedicated earlier check, so its message
      # still wins over this one.
      DML_BODY_KEYWORDS = %w[INSERT UPDATE DELETE].freeze

      # Frozen map of DML body keyword => regex matching the keyword as a
      # bare token anywhere. Used by {#check_forbidden_keywords_in_body!}.
      DML_BODY_REGEXES = DML_BODY_KEYWORDS.to_h do |kw|
        [kw, /\b#{kw}\b/i]
      end.freeze

      # Frozen map of dangerous function name => regex matching a call to that function.
      # Used by {#check_dangerous_functions!}.
      DANGEROUS_FUNCTION_REGEXES = DANGEROUS_FUNCTIONS.to_h do |func|
        [func, /\b#{func}\s*\(/i]
      end.freeze

      # @raise [SqlValidationError] if the SQL is not a safe read-only statement
      def validate!(sql)
        raise SqlValidationError, 'SQL is empty' if sql.nil? || sql.strip.empty?

        normalized = sql.strip

        # Reject multiple statements (semicolons not inside string literals)
        if contains_multiple_statements?(normalized)
          raise SqlValidationError, 'Rejected: multiple statements are not allowed'
        end

        # Check for forbidden keywords at statement start
        check_forbidden_keywords!(normalized)

        # Check for writable CTEs (before body keywords to give better error messages)
        check_writable_ctes!(normalized)

        # Check for a CTE list attached to top-level DML
        check_with_attached_dml!(normalized)

        # Check for row-lock clauses (FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE)
        check_lock_clauses!(normalized)

        # Check for forbidden keywords anywhere in the SQL body
        check_body_forbidden_keywords!(normalized)

        # Check for dangerous functions
        check_dangerous_functions!(normalized)

        # After stripping comments, check again for forbidden keywords that might have been hidden
        check_forbidden_keywords_in_body!(normalized)

        # Enforce the read-only function allowlist (replaces relying solely
        # on DANGEROUS_FUNCTIONS, which cannot enumerate every side-effecting
        # function).
        check_function_allowlist!(normalized)

        # Must start with an allowed prefix
        return if normalized.match?(ALLOWED_PREFIXES)

        raise SqlValidationError, 'Rejected: SQL must start with SELECT, WITH, or EXPLAIN'
      end

      # Check if SQL is valid without raising.
      #
      # @param sql [String] SQL string to validate
      # @return [Boolean]
      def valid?(sql)
        validate!(sql)
        true
      rescue SqlValidationError
        false
      end

      private

      # Check if the SQL contains multiple statements separated by semicolons.
      # Strips SQL comments and string literals before checking.
      #
      # @param sql [String]
      # @return [Boolean]
      def contains_multiple_statements?(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)
        stripped.include?(';')
      end

      # Check if the SQL starts with a forbidden keyword.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_forbidden_keywords!(sql)
        FORBIDDEN_PREFIX_REGEXES.each do |keyword, pattern|
          raise SqlValidationError, "Rejected: #{keyword} statements are not allowed" if sql.match?(pattern)
        end
      end

      # Check if the SQL contains forbidden keywords anywhere in the body.
      #
      # Scans the noise-stripped SQL (comments and string literals removed),
      # not the raw input. A raw scan misreads English words that happen to
      # match a keyword inside a data literal — `WHERE body = 'please update
      # the record'` contains the substring UPDATE but is not a write.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found
      def check_body_forbidden_keywords!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)

        BODY_FORBIDDEN_REGEXES.each do |keyword, pattern|
          raise SqlValidationError, "Rejected: #{keyword} is not allowed" if stripped.match?(pattern)
        end
      end

      # Check if the SQL contains writable CTEs (WITH...DELETE/UPDATE/INSERT).
      #
      # Walks EVERY `AS (...)` body in the statement, not just the first one.
      # The previous implementation anchored a single regex to the WITH
      # leader, so a writable CTE in second-or-later position validated
      # cleanly and PostgreSQL executed it:
      # `WITH a AS (SELECT 1), b AS (DELETE FROM users RETURNING *) SELECT * FROM b`.
      # There is no full SQL parser here, so the walker matches every
      # `AS (` shape and extracts the balanced paren body after it. In an
      # allowed statement the extra matches are harmless: a WINDOW definition
      # (`w AS (PARTITION BY x)`) or a CTE nested inside another CTE body is
      # only rejected when its body *starts* with a DML keyword, which is
      # never legitimate grammar. Scans noise-stripped input for the same
      # reason as {#check_body_forbidden_keywords!}.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a writable CTE body is found
      def check_writable_ctes!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)
        each_as_body(stripped) do |body|
          next unless body.match?(WRITABLE_CTE_BODY_PATTERN)

          raise SqlValidationError, 'Rejected: writable CTEs are not allowed'
        end
      end

      # Check if the SQL carries a row-lock clause ({LOCK_CLAUSE_PATTERN})
      # in any dialect-normalized view of the statement.
      #
      # {#lock_clause_views} produces, for each SQL dialect, the
      # noise-stripped text with every MySQL executable comment
      # (`/*!...*/`) interpreted under BOTH of its possible semantics:
      # replaced by whitespace (version guard unsatisfied — MySQL treats
      # the comment as a plain comment and `LOCK /*!99999 */ IN SHARE MODE`
      # runs as a live lock clause), and replaced by its body (guard
      # satisfied — the body executes in place, so `LOCK /*! IN SHARE */
      # MODE` also runs as one). Running the pattern over every view and
      # rejecting on any match means a lock clause cannot be split or
      # hidden by a comment form without at least one view seeing it,
      # while no comment body is ever hidden from the check.
      #
      # Scans the noise-stripped SQL; see {LOCK_CLAUSE_PATTERN} for why this
      # is a dedicated check instead of a body-keyword entry.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a lock clause is found
      def check_lock_clauses!(sql)
        return unless lock_clause_views(sql).any? { |view| view.match?(LOCK_CLAUSE_PATTERN) }

        raise SqlValidationError,
              'Rejected: row-lock clauses (FOR UPDATE / FOR SHARE / LOCK IN SHARE MODE) are not allowed'
      end

      # Every dialect-normalized view of the SQL the lock-clause check must
      # consider. With {#dialect} known, only that dialect's view is
      # produced (the server will parse the statement one way); without it,
      # both views run as a conservative union. Each view is scanned under
      # both executable-comment semantics; see {#check_lock_clauses!}.
      #
      # @param sql [String]
      # @return [Array<String>]
      def lock_clause_views(sql)
        dialects = dialect ? [dialect] : KNOWN_DIALECTS
        dialects.flat_map do |dialect_name|
          stripped = SqlNoiseStripper.strip_noise(sql, dialect: dialect_name)
          [stripped.gsub(EXECUTABLE_COMMENT_PATTERN, ' '),
           stripped.gsub(EXECUTABLE_COMMENT_PATTERN) { Regexp.last_match[1] }]
        end
      end

      # Check if a CTE list is attached to a top-level data-modifying
      # statement ({WITH_ATTACHED_DML_PATTERN}).
      #
      # PostgreSQL allows `WITH a AS (SELECT 1) DELETE FROM users RETURNING *`;
      # the statement starts with WITH so it passes the allowed-prefix check,
      # and only INSERT ever tripped a body keyword (INTO), incidentally.
      # Runs before {#check_body_forbidden_keywords!} so the WITH-attached
      # shapes get this specific message rather than the generic INTO one.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if DML follows the CTE list
      def check_with_attached_dml!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)
        return unless stripped.match?(WITH_ATTACHED_DML_PATTERN)

        raise SqlValidationError,
              'Rejected: a WITH clause cannot be attached to a data-modifying ' \
              'statement (DELETE/UPDATE/INSERT/MERGE)'
      end

      # Yields the balanced paren body following every `AS (` occurrence.
      #
      # Continues scanning from just inside each match so bodies nested
      # inside an already-yielded body (a WITH inside a CTE) are yielded
      # too. String literals are already stripped, so no paren inside a
      # literal can skew the balance count.
      #
      # @param stripped [String] noise-stripped SQL
      # @yieldparam body [String] text between the parens
      def each_as_body(stripped, &block)
        pos = 0
        while (match = stripped.match(AS_BODY_PATTERN, pos))
          yield balanced_paren_body(stripped, match.end(0) - 1)
          pos = match.end(0)
        end
      end

      # Return the text between the `(` at +open_index+ and its matching
      # `)`. An unterminated body returns the remainder of the string
      # (over-detection only: the body still gets checked).
      #
      # @param text [String]
      # @param open_index [Integer] index of the opening `(` in +text+
      # @return [String]
      def balanced_paren_body(text, open_index)
        depth = 0
        open_index.upto(text.length - 1) do |i|
          depth += 1 if text[i] == '('
          if text[i] == ')'
            depth -= 1
            return text[(open_index + 1)...i] if depth.zero?
          end
        end
        text[(open_index + 1)..]
      end

      # Check if the SQL calls dangerous functions.
      #
      # Scans the noise-stripped SQL so a function name that only appears
      # inside a comment or string literal isn't misread as a call.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a dangerous function is found
      def check_dangerous_functions!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)

        DANGEROUS_FUNCTION_REGEXES.each do |func, pattern|
          raise SqlValidationError, "Rejected: dangerous function #{func} is not allowed" if stripped.match?(pattern)
        end
      end

      # Check every function-call-shaped identifier against ALLOWED_FUNCTIONS.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a non-allowlisted function is called
      def check_function_allowlist!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)

        stripped.scan(FUNCTION_CALL_PATTERN) do
          match = Regexp.last_match
          quoted = !(match[1] || match[2]).nil?
          identifier = match[1] || match[2] || match[3]
          # A bare keyword before `(` is grammar (IN/EXISTS/…), not a call; a
          # quoted name before `(` is always a call, so keyword exclusion
          # applies only to the bare form.
          next if !quoted && FUNCTION_SCAN_EXCLUDED_KEYWORDS.include?(identifier.upcase)
          next if ALLOWED_FUNCTIONS.include?(identifier.downcase)

          raise SqlValidationError,
                "Rejected: function '#{identifier}' is not on the read-only function allowlist. " \
                "Allowed: #{ALLOWED_FUNCTIONS.join(', ')}."
        end
      end

      # Check if the SQL contains a forbidden keyword at a statement-leader
      # position after stripping comments and string literals. This catches
      # comment-hidden injections like "SELECT 1 --;\nDELETE FROM users",
      # and — by also stripping literals, not just comments — avoids
      # rejecting a legitimate value like `body = 'please update the
      # record'`, where UPDATE is English prose inside data, not SQL.
      # {FORBIDDEN_BODY_REGEXES} only matches leader positions (start of the
      # SQL, or right after a `;`/newline), so a column legitimately named
      # after a forbidden keyword (`WHERE do = 1`) is not misread as one.
      #
      # The DML keywords ({DML_BODY_REGEXES}) are then matched as bare tokens
      # across every dialect-normalized view ({#dml_body_views}): they are
      # reserved words, so they can never be bare identifiers the way `do`
      # or `lock` can. Runs after {#check_lock_clauses!} in {#validate!}, so
      # a lock-clause statement (`SELECT 1 FOR UPDATE`) keeps its dedicated
      # message.
      #
      # @param sql [String]
      # @raise [SqlValidationError] if a forbidden keyword is found as a
      #   statement leader, or a DML keyword anywhere in the body
      def check_forbidden_keywords_in_body!(sql)
        stripped = SqlNoiseStripper.strip_noise(sql)

        FORBIDDEN_BODY_REGEXES.each do |keyword, leader_pattern|
          next unless stripped.match?(leader_pattern)

          raise SqlValidationError, "Rejected: #{keyword} statements are not allowed (found in SQL body)"
        end

        dml_body_views(sql).each do |view|
          DML_BODY_REGEXES.each do |keyword, pattern|
            next unless view.match?(pattern)

            raise SqlValidationError, "Rejected: #{keyword} statements are not allowed (found in SQL body)"
          end
        end
      end

      # Every dialect-normalized view of the SQL the DML body-token scan
      # must consider, mirroring {#lock_clause_views}: with {#dialect} known,
      # only that dialect's view (the server parses the statement one way, so
      # a MySQL `\'` escape must hide prose from this scan); without it, both
      # normalizations run as the conservative union. {SqlNoiseStripper}
      # leaves MySQL executable comments (`/*!...*/`) visible in every view,
      # so DML inside them stays detected.
      #
      # @param sql [String]
      # @return [Array<String>]
      def dml_body_views(sql)
        dialects = dialect ? [dialect] : KNOWN_DIALECTS
        dialects.map { |dialect_name| SqlNoiseStripper.strip_noise(sql, dialect: dialect_name) }
      end
    end
  end
end
