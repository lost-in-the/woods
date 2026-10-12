- The incremental equivalence harness and the fixture boot scripts read
  Woods-written JSON through `Woods::AtomicFile.read`. A bare `File.read`
  tagged multibyte unit source US-ASCII under a POSIX locale and the
  comparison raised before it could report a difference.
