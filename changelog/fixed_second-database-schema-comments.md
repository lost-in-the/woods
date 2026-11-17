- A model on a second database now gets its own table's indexes and foreign keys in its schema header comment.
  The header read them through `ActiveRecord::Base.connection`.
  A `connects_to` model therefore showed the default database's table of the same name, or no sections at all.
  The header and `metadata[:foreign_keys]` now come from one foreign key read, so they cannot disagree.
  The model extractor's index and foreign key reads now go through `model.connection_pool.with_connection`.
  `model.connection` kept the connection leased to the worker thread for the thread's life.
  With concurrent extraction and a one-connection pool, the tables worker then timed out.
  That run published a generation without the second database's tables.
  Before Rails 7.2, Active Record's own schema reads still lease the connection that way.
  A header section whose read fails now prints `Indexes: unknown (could not be read)` or the same for foreign keys.
  Before, a failed read looked like a table with no indexes.
  A table that truly has no indexes or foreign keys still prints no section.
