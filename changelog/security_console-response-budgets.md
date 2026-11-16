- Every Console tool now bounds the size of its response.
  A string value over `console_max_value_bytes` (default 64 KiB) is replaced whole by a `value_omitted` marker.
  No prefix of the omitted value is returned.
  A result or encoded tool response over `console_max_response_bytes` (default 4 MiB) is refused.
  So is a result nested deeper than 100 levels, or a cyclic one.
  The refusal reads `response_budget_exceeded` and names no value or field.
  An oversized field name or SQL column header is refused rather than renamed.
  Column and key/value redaction still run first, so a protected value stays redacted, never omitted.
  The budgets bound what Woods returns, not the memory a database driver uses before Woods sees a value.
