- Add a `database_table` unit for every table in the live schema, across all
  connected databases, read from the connection rather than from
  `db/schema.rb`. Each unit records columns, indexes, foreign keys, the
  primary key, the database, and the owning model. A table no model owns
  (a legacy table, another application's table, a join or backup table) is
  flagged `model_less` and listed under `unmodelled_tables` in
  `graph_analysis.json`. Identifiers are `table:<name>`, or
  `table:<database>.<name>` with more than one database. Models gain a
  `via: :table` edge to their table and foreign keys become table-to-table
  `via: :foreign_key` edges. Table units take no part in PageRank or the hub,
  orphan and dead-end lists. A schema change applied with no file change
  needs a full extraction. The Rails 6.0 database-name fallback (no
  `connection_db_config`) is untested in CI.
