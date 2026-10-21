- Keep method effects and action facts within their resolved source definitions,
  including same-line methods, aliases, nested definitions and receiver-changing
  blocks. Dynamic render targets retain source evidence, and splatted
  `params.expect` arguments no longer interrupt extraction.
- Refresh inherited mailer callback facts after parent or concern edits through
  app-owned inheritance edges. Run a full extraction once after upgrading to
  populate these edges in retained indexes.
- Preserve protected-field SQL refusals for legal PostgreSQL relation aliases
  while retaining unaliased ON/USING and MySQL STRAIGHT_JOIN column projections.
