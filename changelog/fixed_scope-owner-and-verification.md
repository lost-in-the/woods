- A model unit's `scopes` no longer lists a nested model's scopes, and no longer verifies dead ones.
  It listed every `scope` call in the file, including those under `if false` or inside a method body.
  A declaration span (`kind: scope`) on any of them was published as `verified`.
  Each `scopes` entry now carries `confidence`.
  It is `verified` when the call is written in the model's own class body and the live class answers the name.
  The live class must answer it as an Active Record scope of its own, not as a class method or an enum scope.
  Every other entry stays, `static`, and its declaration span is `static` too.
  A nested model's scopes appear on the nested model's unit.
