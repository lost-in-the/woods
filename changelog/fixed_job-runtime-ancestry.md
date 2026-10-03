- Job extraction admits classes by runtime ancestry as well as by source
  markers: any class defined in the application whose ancestors include
  `ActiveJob::Base`, `Sidekiq::Job`, or `Sidekiq::Worker`. Marker-less worker
  leaves and iterable jobs without `def perform` become `job` units, so
  `perform_async` call sites now resolve to them. Gem-defined jobs stay out.
  Class-discovered jobs resolve their file under every job directory, and job
  units record `metadata[:parent_class]`.
