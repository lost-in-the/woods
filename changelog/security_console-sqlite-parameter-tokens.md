- `console_sql` on SQLite refuses parameter tokens (`?`, `?NNN`, `:name`, `@name`, `#name`, `$name`) with one message.
  The tool passes no bind values, and SQLite binds `NULL` to an unbound parameter.
  Such a statement used to run, with `NULL` where each token stood, and the SQL policy did not read the tokens.
  This changes what a configured table block or redaction hides only by refusing more: no statement it refused now runs.
  The characters stay usable inside string literals, comments and quoted identifiers.
  PostgreSQL and MySQL are unaffected.
