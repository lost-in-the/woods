- A targeted refresh or an incremental run no longer leaves the index reading as `drifted` right after it adds a file
  (#1124). `refresh` also re-runs every whole-app family whose rule matches a file of a named family that the
  family has not recorded yet, so `refresh(:rake_tasks)` after a new rake file re-runs `test_mappings` and
  `refresh(:factories)` after a new factory file re-runs `test_support`. When an
  incremental run skips the table family because no schema input changed and table ownership is unchanged, it
  records the new model-directory file in `whole:database_tables` without re-running the family. A later edit to
  the file still reads as changed.
