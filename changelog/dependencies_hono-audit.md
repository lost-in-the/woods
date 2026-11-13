- The MCP client test dependencies resolve `hono` 4.13.18 (was 4.13.13), clearing three moderate advisories
  (GHSA-4m76-xfj5-7975, GHSA-h7mg-cq63-vhpq, GHSA-3gg2-335m-rxc6) that failed `npm audit` in the MCP transports CI job.
  It is a development-only transitive dependency; the gem does not ship it.
