- **Edge shape change.** Migration and database view units now point at
  `database_table` units instead of at a model name derived from the table
  name. A migration links every table it creates, alters, drops or references
  with `via: :migrates`; a view links each source table with
  `via: :view_source`. The `via: :table_name` and `via: :reference` model
  edges remain only where a model owns the table today, and they name that
  owner. A table the live schema no longer has gets no edge and is listed in
  the migration's `tables_unresolved`, so migrations for renamed or removed
  models no longer carry dangling model edges. Consumers that walked
  `table_name` edges from migrations to reach a table should follow
  `migrates` instead. Run a full extraction after upgrading.
