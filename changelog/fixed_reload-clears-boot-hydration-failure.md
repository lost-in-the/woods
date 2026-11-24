- A successful `reload` of the Index MCP server now clears the boot hydration failures of the stores it replaced.
  A store that could not be read at boot used to keep `codebase_retrieve` refusing (`phase: 'boot'`) until a restart.
  `woods_status` kept reporting `bootstrap.status: degraded` after a reload had swapped in readable stores.
  A failure of a store the reload did not replace stays recorded, and the status now names it.
  A degradation from an unreachable provider is left as it is.
