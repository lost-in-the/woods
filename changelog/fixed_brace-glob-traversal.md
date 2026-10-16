- Refuse a root-relative glob whose brace alternation leaves the root, such as
  `{../shared,app}/**/*.rb`, as `../shared` already was.
