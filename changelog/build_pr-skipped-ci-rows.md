- On a pull request, the CI rows that do not run (unit specs on Ruby 3.0, 3.1 and 3.2; booted extraction on
  Rails 6.0, 6.1, 7.0 and 7.1) keep their names and still finish green in seconds without running a test.
  A new check, `Not run on this PR: Ruby 3.0-3.2 units, Rails 6.0-7.1 booted (label full-matrix to run)`,
  lists them in its name, step summary and a notice; it exists only on pull requests that skip them.
  The `full-matrix` label runs every row on a pull request: adding it dispatches CI on the branch
  (`.github/workflows/full-matrix.yml`), and later pushes to the labeled pull request run every row.
  A `CI gate` check needs every other CI job and fails when any fails or is cancelled, giving rulesets one
  stable context to require.
