- Configured `event_patterns` can name the event with a `(?<name>...)` capture
  and record a `(?<scope>...)` capture. Event units from configured patterns
  also carry `metadata.scopes` and `metadata.sub_events`, filled from that
  capture and from `scope:` / `event:` literals passed to the matched call,
  directly, in a hash literal, or one level inside a `merge`-family argument.
  The identifier stays the event name. A pattern with named groups but no
  `(?<name>...)` raises `Woods::ConfigurationError` at configure time. Apps
  without `event_patterns` are unchanged.
