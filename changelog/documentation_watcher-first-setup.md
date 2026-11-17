- The README and Getting started now lead with the watcher: install, set up the watcher for your development startup
  with `bin/rails generate woods:watch` (`puma`, `procfile` or `external` mode), start the app, and the watcher builds
  the first index by itself.
  A manual `bin/rails woods:extract` stays documented for apps without a watcher and for CI.
  The README's "check installed capabilities" is now a plain check: `bin/rails generate woods:watch --help`.
  The watch guide no longer says a new worktree needs an index before its daemon can run.
