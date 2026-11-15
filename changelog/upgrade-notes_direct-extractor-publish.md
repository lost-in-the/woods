- A direct `Woods::Extractor#refresh`, `#extract_changed` or `#extract_all` call now waits for the index writer lock
  to publish (`WOODS_LOCK_WAIT`), and refuses when another writer published meanwhile; retry it, or use the rake tasks.
