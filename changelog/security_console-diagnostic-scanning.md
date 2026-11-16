- Woods now scans every field it writes to a Console diagnostic log before writing it.
  The scan uses the credential patterns and the active credential index, on stdio and HTTP.
  It covers executor errors, unexpected dispatch failures, table-gate refusals, skipped models and a failed eager load.
  Before, some of these logs carried exception messages or arguments unscanned, or scanned them by pattern only.
  A field over 8 KiB is replaced whole by a `DIAGNOSTIC_OMITTED` marker, and an unscannable one by `REDACTION_FAILED`.
  A scanning failure never ends the request, and client error wording is unchanged.
  A skipped model during HTTP startup is now logged at `warn` instead of `debug`.
  When the Rails credentials cannot be read at boot, dynamic diagnostic text is replaced by a fixed marker until a
  successful credential rebuild.
