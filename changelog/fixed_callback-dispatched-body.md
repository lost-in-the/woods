- Model callback `side_effects` now describe the method body Ruby runs for the callback.
  A method defined twice in one class reported the first definition, which Ruby discards.
  A method a prepended module overrides reported the class's own body.
  A same-named method in a class earlier in the model file could be read in place of the model's.
  The analysis now maps the method's `source_location` into the model file or a concern and reads the def there.
  When several defs of the name start on that line, the one at the column Ruby compiled the method at is read.
  On a Ruby that reports no column, the owner's def is read; of several, the last one of a statement list.
  Defs in exclusive branches (`if`/`else`, `case`, a ternary, `&&`, a modifier `if`) are then `unsupported`.
  If no def can be told apart, the callback is `unsupported`, never another def's effects.
  When that body calls `super`, the body `super` reaches is read too, its operations after the first body's.
  A callback whose body, or a body its `super` reaches, lies outside those files is `unsupported`.
  A definition of the same name no longer stands in for it.
