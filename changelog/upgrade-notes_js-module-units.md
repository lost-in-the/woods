- Run a full `woods:extract` after upgrading to index JavaScript modules and
  replace the former dangling `stimulus_controller` edges on components and
  templates. Incremental runs re-resolve those edges only when a module under
  `config.javascript_paths` changes.
