- A class with job ancestry (`ActiveJob::Base`, `Sidekiq::Job`, or
  `Sidekiq::Worker`) defined in an application file is exactly one unit, a
  `job`, even when it is the primary class of an `app/models` file.
  PoroExtractor defers to the shared `Woods::Extractors::JobAncestry`
  predicate instead of emitting a duplicate `poro` unit, and the job unit
  keeps its job metadata, `job_enqueue` edges, and resolved source
  references.
