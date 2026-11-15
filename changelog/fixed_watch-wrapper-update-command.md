- The generated `bin/woods-watch` names the command that changes its setup,
  `bin/rails generate woods:watch --operation update`, instead of the bare `woods:watch --operation update`.
  An existing wrapper with the old comment still repeats, updates and removes without a conflict;
  the next setup or update rewrites its comment line.
