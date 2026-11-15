- The watch daemon no longer runs a full extraction per batch the watcher splits a burst of changes into.
  Under polling, a checkout or pull touching many files and an initializer could arrive as three batches.
  That cost two storm full runs, a restart and a third full run, each publishing a generation.
  Before a full extraction the daemon now compares restart inputs on disk with its boot snapshot.
  A restart input changed since the boot restarts the daemon at once, carrying the batch.
  A batch whose bytes the published generation already captured no longer counts as a storm.
  Once the boot has finished, a restart input rewritten with the bytes the boot read no longer restarts the daemon.
  Examples are `db:prepare` dumping an unchanged `db/schema.rb`, a stash round trip, or `bundle check`.
  `bundle check` in another container touches the lockfile without changing it.
  It used to cost a restart and a full extraction each time, and sometimes two restarts.
  A change made after a full extraction started still costs a restart and a second full run.
