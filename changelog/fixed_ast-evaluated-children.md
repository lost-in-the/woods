- The normalized AST, mostly its Prism adapter, no longer drops child expressions that Ruby evaluates.
  Flows, callback `operations`, method effects and method call graphs now see a call in a hash key, value or `**splat`.
  They also see calls in string and heredoc interpolation, a `yield` argument and a block-pass (`run(&Builder.build)`).
  Every later `rescue` branch, its exception list (`rescue *Errors.list`) and the `else` of a `rescue` are kept too.
  Block and lambda parameter defaults, `class << expr`, `def (expr).name` and `rescue => record.error` are kept too.
  So is the expression under a constant path (`builder::OPTIONS`).
  Both adapters now keep default parameter values (`def call(client: Client.new)`) in a `:parameter_defaults` child.
  That child follows the body statements, and flow operations list its calls ahead of the body.
  A file containing an empty `()` no longer fails to parse.
  An over-claim is removed: code that does not run where it is written no longer counts as run.
  In flows and callback `operations`, `hook = -> { NotifyJob.perform_later }` used to list an enqueue and lists none.
  The same holds for `lambda {}`, `proc {}` and `Proc.new {}` bodies and for a `defined?` operand.
  A lambda or proc literal no longer adds a `lambda` or `proc` call operation either.
  A method defined inside another no longer adds its defaults or body to the enclosing flow: they run when it is called.
  Only the receiver of a nested `def (expr).name`, which runs when the method is defined, stays in that flow.
  Method effects no longer read events, external calls or same-class calls there.
  Their job, mailer and service names still come from the method text, so a lambda body still adds those.
  An incremental run keeps the old operations, method effects and call graphs of every file it does not re-extract.
  Run a full extraction after upgrading to pick up the recovered calls.
