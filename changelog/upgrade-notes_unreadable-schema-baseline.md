- `woods:incremental` and `woods:refresh` now refuse an index whose full extraction recorded an unreadable
  database schema, and `woods:seed` refuses it as a seed. Prepare the database (`bin/rails db:prepare`) and run
  one full `woods:extract`. They also refuse a run that would rewrite models, table units or view units while
  the database cannot be read, instead of publishing those units without columns; edits that touch none of
  them still go through. A watch daemon reports such cycles as failed until the database is ready (and, over an
  unreadable index, until a full run). Indexes written before this release have no `schema_readability` record
  and are not refused for it.
