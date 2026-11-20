- During extraction the inlined concern blocks of a unit's source are now decoded once, not four times.
  The method table, the callback declaration sites and the file-line locator of each split the source into lines and
  scanned it for block frames on their own; they now share one result per distinct source for the run.
