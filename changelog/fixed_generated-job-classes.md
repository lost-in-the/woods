- Runtime job discovery skips a class whose definition site does not
  declare it, such as a worker built with `Class.new` and `const_set` by a
  generator module. Such classes previously became `job` units carrying the
  generator file's path and source.
