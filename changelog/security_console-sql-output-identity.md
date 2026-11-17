- `console_sql` keeps each protected value under its own result header.
  This changes what a configured column or key/value redaction hides: values it missed before are now refused.
  A result that names a protected column more than once is refused before any row is returned.
  On SQLite the row-cap subquery renamed a repeated column to `secret:1`.
  Redaction did not match that name, so the repeated value was returned unredacted.
  While any redaction is configured, positional `ORDER BY` or `GROUP BY` is refused beside `*` or `alias.*`.
  An ordinal past the named columns could reach a protected column inside the wildcard and sort rows by its value.
  A statement with an unterminated block comment is refused before the row cap is appended.
  SQLite would read the appended cap as comment text.
  Statements that select each protected column once, and positional ordering over named columns, are unchanged.
