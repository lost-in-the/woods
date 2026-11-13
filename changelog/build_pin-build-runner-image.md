- The CI `build` job now runs on `ubuntu-24.04`, not `ubuntu-latest`.
  It pins Ruby 3.3.10 exactly so the release artifact rebuilds to identical bytes.
  That patch is not built for Ubuntu 26.04, so the job failed once `ubuntu-latest` moved to it.
