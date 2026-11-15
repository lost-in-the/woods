- Run one full extraction (`bin/rails woods:extract`) after upgrading.
  The source-reference cache (`source_references.json`) is now format 9; Woods 2.1 wrote format 3.
  Entries below that name formats 4 to 8 describe steps between those two releases.
  The cache also records the caller policy (`source_reference_callers`) that produced its edges.
  On first use, `woods:incremental`, `woods:refresh` and the watch daemon refuse a cache of any earlier format,
  or one written under a different caller policy, with `Source-reference baseline needs a full extraction`.
  They do not rebuild the cache themselves.
  The previously published generation stays active and readable until the full extraction finishes,
  and `woods:validate` reports `Incremental: needs full extraction` meanwhile.
