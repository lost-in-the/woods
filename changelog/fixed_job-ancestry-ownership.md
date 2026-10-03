- Runtime job discovery no longer claims a class that is the primary
  constant of a file outside the job directories (for example a Sidekiq
  worker or an `ApplicationJob` base defined as the main class of an
  `app/models` file). Those stay `poro` units, as before, instead of
  collapsing to a duplicate `job` node and losing their source references.
  Jobs nested inside such classes are still admitted.
