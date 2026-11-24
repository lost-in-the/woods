- Concurrent extraction no longer drops a second database's tables when that database's pool is small.
  Workers were sized by the default pool alone.
  A worker then waited out `checkout_timeout` on the second pool, and its table listing came back empty.
  The worker count now follows the scarcest writable pool.
  With no free connection, the extractors run on the calling thread.
  A full run now refuses when a schema read fails on a database the same run could otherwise read.
  That is a checkout timeout or a failed connection on a pool that answered another of the run's queries.
  A refused statement counts too.
  So do the index and foreign key reads for a model's schema header, which still show as unknown.
  It raises `Woods::ExtractionError` naming the extractors, and the previous generation stays active.
  A database no read in the run reaches is published and warned about, as before.
  That covers no connection, no database, and a pool held elsewhere for the whole run.
  Queries of other application threads do not count as the run's reads.
