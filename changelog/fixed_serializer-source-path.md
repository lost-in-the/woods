- Class-discovered serializers whose source cannot be resolved get a nil
  `file_path` instead of a fabricated `app/serializers/` path, so an
  incremental run no longer prunes a unit a full extraction still emits.
