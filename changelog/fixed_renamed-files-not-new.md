- Git `change_frequency` no longer reads a file renamed inside the 365-day window as `:new` when its content is
  older than the window.
  A creating commit that also deletes a path is read again with git's rename detection (one extra `git log`
  over only those commits), and a rename is followed back to the commit that created its source.
  A file created inside the window and renamed later stays `:new`.
