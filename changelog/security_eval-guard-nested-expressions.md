- The Console `console_eval` guard now refuses a denied call or constant wherever Ruby would evaluate it.
  That includes a hash key, value or `**splat`, string and heredoc interpolation, and a `yield` argument.
  It also covers a later `rescue` branch, its exception list, the `else` of a `rescue` and a block-pass expression.
  Default parameter values of a method, block or lambda are covered too.
  So are a constant path under an expression, `class << expr`, `def (expr).name` and a `rescue => target`.
  Before, with Prism, `{ key: ENV.to_h }` and `"#{Rails.application.credentials.secret_key_base}"` passed the check.
