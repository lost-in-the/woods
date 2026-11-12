- Lines are limited to 120 columns in every file type.
  RuboCop's `Layout/LineLength` now covers `lib/woods/mcp`, `lib/woods/extractors` and `lib/tasks`, which it excluded.
  `script/check-line-length` holds the Markdown, YAML and shell lines a pull request adds to the same width
  and runs in the CI lint job; existing lines are not reflowed.
  Markdown prose is written one sentence per line.
