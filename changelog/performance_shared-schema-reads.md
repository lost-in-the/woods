- Full extraction reads each table's schema once per run.
  The model and database table extractors shared nothing before: each asked the connection for the same indexes,
  foreign keys and primary keys, and the model extractor asked for a model's foreign keys twice.
  The database table extractor now also takes a table's columns and primary key from Active Record's schema cache,
  which the model extractor has already filled, so PostgreSQL runs its primary key query once per table, not twice.
  On a 1,545-table testbed app, full extraction went from 78.2 s to 61.2 s on PostgreSQL and from 53.7 s to 48.2 s
  on SQLite, with identical output.
  Each run empties Active Record's schema cache when it starts, so a long-lived process such as the watch daemon,
  or an application calling `Woods.extract!`, reads a schema a migration has changed. It empties every pool the
  connection handler lists, connected or not, without checking out a connection, and asks Rails 7.1 and later for
  every role (`:all`), which keeps 7.1 from printing a deprecation. Only a pool emptied that way is read through;
  any other pool is read from the database. Where a schema cache dump could load (`SCHEMA_CACHE`, a configured
  `schema_cache_path`, or a `*schema_cache*` file under `db/` or the directory `config.paths["db"]` names), the cache
  is neither emptied nor read, and the table extractor reads the database as before.
