- Keep callback column-write detection linear on adversarial source.
  `update_column` followed by a long run of spaces, and `update_columns(`
  repeated without a closing paren, each took time quadratic in the method
  body on Ruby 3.0 and 3.1. A source nested too deeply to parse is now
  treated as unparseable instead of raising `SystemStackError`.
