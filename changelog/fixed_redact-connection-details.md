- Boot and retrieval diagnostics now redact database connection details in every place they appear.
  That covers the MCP servers' boot messages, `woods_status`, tool error responses, task records and their logs.
  One helper, `Woods::DiagnosticRedaction`, applies the same rules at each of these sites.
  The pgvector schema setup error no longer carries the database adapter's error as its cause.
