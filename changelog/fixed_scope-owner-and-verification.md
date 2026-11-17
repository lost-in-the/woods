- A model unit's `scopes` no longer lists a nested model's scopes, and verifies only names the live class answers.
  It listed every `scope` call in the file, including those under `if false` or inside a method body.
  A declaration span (`kind: scope`) on any of them was published as `verified`.
  Each `scopes` entry now carries `confidence`.
  It is `verified` when the call is inside the model's own class declaration and the live class answers the name.
  The live class must answer it as an Active Record scope of its own, not as a class method or an enum scope.
  A name is an enum's scope only when that enum's whole `V` and `not_V` family answers as scopes.
  The method-friendly aliases Rails 6.1 and later define (`in_progress` for `in-progress`) form a family too.
  An explicit scope named for a value of an enum with `scopes: false` is therefore `verified`.
  Every other entry stays, `static`, and its declaration span is `static` too.
  A nested model's scopes appear on the nested model's unit.
  The live check cannot tell which call defined a name.
  So a dead declaration reads `verified` when a concern defines a live scope of the same name.
