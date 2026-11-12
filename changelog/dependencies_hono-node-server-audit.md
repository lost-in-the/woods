- The MCP client test dependencies resolve `@hono/node-server` 2.1.8 (was 2.1.5), clearing two moderate advisories
  (GHSA-qv5m-9pm6-hqp3, GHSA-jpvv-r467-5p4w) that failed `npm audit` in the MCP transports CI job.
  It is a development-only transitive dependency; the gem does not ship it.
