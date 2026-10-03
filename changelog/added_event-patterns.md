- Add `config.event_patterns` so `EventExtractor` recognizes an application's
  own event wrapper (for example `Ledger.emit(:checkout_completed)`) alongside
  ActiveSupport::Notifications and Wisper. Each entry names a `role`
  (`:publisher` or `:subscriber`), a `pattern` whose first capture group is the
  event name, and a `system` label. Invalid entries raise
  `Woods::ConfigurationError` at configure time. The label lands in
  `metadata.pattern` and a new `metadata.systems` list, never in the
  identifier. Without the option, event units are unchanged. Changing
  `event_patterns` needs a full extraction.
