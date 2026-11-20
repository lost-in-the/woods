- A direct `Woods::Extractor#refresh`, `#extract_changed` or `#extract_all` call now waits for the index writer lock
  to publish (`WOODS_LOCK_WAIT`).
  When the lock stays held, or another writer published meanwhile, the call publishes nothing and returns normally.
  The previous generation stays active, and the extractor records the failure as a `Woods::ExtractionError`.
  Call `raise_on_publication_failure!` on the extractor after the run to raise it, then retry.
  `Woods.extract!`, `Woods.extract_changed!` and the rake tasks already do this.
