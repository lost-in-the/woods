- Add `config.external_table_consumers` and
  `config.external_table_consumers_path` to declare other applications that
  read or write this database's tables, as plain data (`{ "storefront" =>
  %w[products orders] }` for reads, `{ "public-site" => { reads: [...],
  writes: [...] } }` for both, or a YAML file of the same shape). Each
  declared application becomes an `external_consumer` unit with
  `via: :reads_table` and `via: :writes_table` edges to the table units, so
  `dependents` of a table lists it. Both settings are
  validated at assignment and raise `Woods::ConfigurationError` otherwise.
  An incremental run follows the declared file; a change to the setting
  itself needs a full extraction.
