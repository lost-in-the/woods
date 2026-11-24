- Impact reports no longer raise `callback_side_effect_change` or `filter_chain_change` for moved lines alone (#1085).
  A callback operation's `line`, `statement_line` and `file` are left out of the comparison.
  So are a filter's declaration `line` and `file`.
  The risk evidence still shows them.
