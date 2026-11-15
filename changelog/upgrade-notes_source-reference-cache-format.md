- Run one full extraction (`bin/rails woods:extract`) after upgrading.
  The source-reference cache (`source_references.json`) is now format 9; Woods 2.1 wrote format 3.
  Entries below that name formats 4 to 8 describe steps between those two releases.
  The cache also records the caller policy (`source_reference_callers`) that produced its edges.
  On first use, `woods:incremental`, `woods:refresh` and the watch daemon refuse a cache of any earlier format when
  the index holds a model, controller, service or other class-based unit whose Ruby file is under `app/` or `lib/`.
  The refusal reads `Source-reference baseline is missing or incompatible. Run bin/rails woods:extract once for a
  full extraction; the previous published generation remains active. woods:validate reports incremental readiness.`
  An index without such a unit runs on with an empty cache baseline.
  A cache written under a different caller policy is refused later in the run, with
  `Source-reference baseline needs a full extraction (source_reference_callers changed).
  Run bin/rails woods:extract; the previous published generation remains active.`
  Neither run rebuilds the cache, and the previously published generation stays active until the full extraction
  finishes.
  `woods:validate` reads only the files on disk: for an index 2.1 wrote it prints `Incremental: build mismatch (...)`,
  and for another unusable cache `Incremental: needs full extraction (...)`.
  It does not compare the live `source_reference_callers`, so after changing that setting it can still print
  `Incremental: ready` while the run refuses.
