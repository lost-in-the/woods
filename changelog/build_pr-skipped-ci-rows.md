- On a pull request, the CI rows that do not run (unit specs on Ruby 3.0, 3.1 and 3.2; booted extraction on
  Rails 6.0, 6.1, 7.0 and 7.1) are now named `... (not run on PRs)`, so their seconds-long green checks no longer
  read as tested. The name repeats the condition that gates their steps. `main` and tag runs keep their names.
  The `full-matrix` label runs every row on a pull request: adding it dispatches CI on the branch
  (`.github/workflows/full-matrix.yml`), and later pushes to the labeled pull request run every row.
