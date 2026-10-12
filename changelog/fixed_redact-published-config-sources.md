- Every unit published from configuration source now passes through the
  same credential redaction. `scheduled_job` units built from a Ruby or
  YAML schedule source (`config/initializers/sidekiq.rb`, `config/schedule.yml`)
  and `concern` units built from a module declared in `config/initializers/`
  published the file verbatim, so a Redis URL or an API key beside the
  schedule or the module reached the index. A `redirect(...)` route now
  redacts the userinfo of its target in `metadata.redirect_target` and in
  the unit source. The Ruby guard also withholds a generated-looking literal
  (a long run mixing letters and digits) assigned to any key the YAML
  extractor treats as sensitive (`pepper`, `key_derivation_salt`,
  `encryption.primary_key`, `*_webhook`), not only credential-named keys;
  readable settings under those names (`key: '_session'`) are kept. YAML
  mapping keys that read as generated tokens are published as `[REDACTED]`,
  so a mapping keyed by secrets no longer lists them in `key_paths`.
