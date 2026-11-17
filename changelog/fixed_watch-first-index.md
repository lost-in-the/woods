- The watch daemon now builds a first index for a small application.
  With no generation published, startup ran an incremental extraction unless more than 50 actionable files changed.
  The extractor refuses an incremental run without a baseline, so the watcher stayed degraded at generation 0.
  Startup with no generation now runs one full extraction, whatever the file count, including an empty tree.
  A `generation.json` that cannot be read no longer starts a full extraction the writer would refuse.
  The watcher stays degraded and names the file and the restore step.
