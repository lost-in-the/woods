- Boot and retrieval diagnostics now redact database connection details in every place they appear.
  That covers the MCP servers' boot messages, `woods_status`, tool error responses, task records and their logs.
  One helper, `Woods::DiagnosticRedaction`, applies the same rules at each of these sites.
  The pgvector schema setup error no longer carries the database adapter's error as its cause.
  Registered connection values are removed whole, overlapping ones included.
  They and the other rules are matched against the original text, so a registered `password` cannot hide `password=x`.
  A registered URL's password given as a query parameter, such as `?password=x`, is registered as well.
  Unquoted values that hold punctuation, host names in PostgreSQL and MariaDB errors and invalid UTF-8 are covered.
  Store, boot and reload errors with a redacted message no longer keep the error they translate as their cause.
  A Qdrant URL that the parser rejects is left out of its error message.
  Any other URL loses its whole credential run, through the last @ before its host.
