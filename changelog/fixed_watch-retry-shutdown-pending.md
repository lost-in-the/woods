- A watch daemon stopped while a heartbeat retry was still extracting no longer forgets the paths that retry owed.
  Shutdown killed the retry thread after its bounded wait but did not wait for the kill to finish.
  The daemon then saved `watch_pending.json` before the killed cycle had put its paths back, so the file was empty.
  When another writer had published after the edit, the next start-up read the file as unchanged and never
  extracted it.
  Shutdown now waits for the killed retry cycle, as it already did for the watcher thread, before it saves pending
  paths and releases its claim.
