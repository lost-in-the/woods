- A locked writer (`woods:extract`, `woods:incremental`, `woods:refresh`, the gem map and the MCP `pipeline_extract`
  run) no longer waits up to a second after its work ends. The lock heartbeat now wakes as soon as the block finishes
  instead of sleeping out its current one-second tick; beat timing is unchanged.
