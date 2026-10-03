- **Graph change:** event units now depend on the classes that publish and
  subscribe to them, not on every constant those files mention. Each
  publisher file contributes `{type: :class, target: <owner>, via: :published_by}`
  and each subscriber file `{..., via: :subscribed_by}`, where the owner is the
  constant the file's autoload path governs (else its first class, else its
  primary module). `dependents` of an emitting class now reaches its events;
  the co-location `code_reference` edges from events are gone. Applies to
  ActiveSupport::Notifications, Wisper, and configured `event_patterns`.
  Re-extract to pick up the new edges.
