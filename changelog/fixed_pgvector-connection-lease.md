- The packaged MCP server can serve a pgvector index on Active Record 8.0 and 8.1 again.
  It opened its `WOODS_PG_URL` connection with `ConnectionPool#connection`, which Active Record 8.0 removed.
  Boot then failed with a `NoMethodError` backtrace.
  It now calls `lease_connection` where the pool has it (7.2 and later) and `connection` before 7.2.
  That also ends the 7.2 deprecation warning.
  A failure to open that connection, a missing `activerecord` or `pg` gem included, is now one `BootstrapError` line.
  The URL and its password are left out of that line.
  A pgvector store that cannot be opened at boot, such as a database that refuses the connection, gives the same.
  Both exit with status 2 instead of a backtrace.
