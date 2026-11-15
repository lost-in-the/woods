- Say when a full extraction could not read the database schema, instead of publishing models without columns (or
  no models at all) as if that were the application. This happened in a fresh worktree or a new clone before
  `bin/rails db:prepare`, or with the database server down. The manifest records `schema_readability` per
  database (`readable`, `unreachable`, `empty`). `woods:extract` prints a warning naming each database and the
  fix, and `woods:validate` lists it. Incremental readiness reports `needs full extraction` for such an index.
