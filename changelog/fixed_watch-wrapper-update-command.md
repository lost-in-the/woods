- The generated `bin/woods-watch` names the complete command that changes its setup, for its own mode:
  `bin/rails generate woods:watch --operation update --mode <mode>`, plus the Procfile and Foreman command
  in procfile mode, instead of the bare `woods:watch --operation update`, which refuses without `--mode`.
  An existing wrapper with the old comment still repeats, updates and removes without a conflict;
  the next setup or update rewrites its comment.
