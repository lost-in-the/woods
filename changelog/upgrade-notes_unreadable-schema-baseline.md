- `woods:incremental` and `woods:refresh` now refuse an index whose full extraction recorded an unreadable
  database schema, and `woods:seed` refuses it as a seed. Prepare the database (`bin/rails db:prepare`) and run
  one full `woods:extract`. A watch daemon over such an index reports each incremental cycle as failed until that
  full run. Indexes written before this release have no `schema_readability` record and are not affected.
