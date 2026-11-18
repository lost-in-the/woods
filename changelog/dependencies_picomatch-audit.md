- The MCP transports CI job audits the Inspector's dependencies with `script/npm-audit`,
  which allowlists picomatch advisory GHSA-fc5q-39xc-vjpf by id.
  Upstream disputes the report and no patched release exists;
  picomatch is a test-only transitive dependency the gem does not ship, and CI supplies no untrusted glob patterns.
  Every other advisory at moderate or above still fails the job,
  as does the entry once the advisory leaves the report or its re-check date (2027-02-15) passes.
