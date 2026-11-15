- The Docker guide now says that the Puma watcher mode works inside the application container,
  that the watcher already polls inside a container or without the `listen` gem,
  and how to read which backend it chose from its startup log before setting `WOODS_WATCH_POLL=1`.
- The watch guide's `WOODS_WATCH_POLL` row and backend table now state the container polling default,
  and the automatic-maintenance page says the watcher builds the first index, with `woods:extract` as the manual path.
