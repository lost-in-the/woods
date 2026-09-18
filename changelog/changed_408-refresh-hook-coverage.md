- Expand opt-in refresh hooks to the shared extraction input rules, including
  services, controllers, jobs, views, locales, and supported tests/lib paths.
  Restart inputs request fresh full extraction. Preserve queued edits across
  failures and daemon deferral, bound the worker lifetime, and carry JSON batches
  through Docker command prefixes without host-bundle or environment-forwarding
  assumptions. Existing manual incremental and watch behavior is unchanged.
