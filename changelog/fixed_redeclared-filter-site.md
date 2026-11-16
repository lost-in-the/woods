- A controller filter declared twice in one file, for example `before_action :x` and later
  `prepend_before_action :x, only: :show`, now records the later declaration's `line`, the one Rails keeps,
  in `metadata[:filters]` and in request flows.
