- Concern `include`/`extend` edges and `metadata.included_modules`, and the `*Helper` includes of Phlex,
  ViewComponent and mailer units, now come from real `include`/`extend` calls with constant arguments in the
  Prism tree.
  A comment such as "the include of this module" no longer produces a concern dependency named `of`, and a
  string, heredoc, method name or `extend self` declares nothing.
  Every constant of `include A, B` and of a multi-line argument list is now read, not only the first.
  A concern's `metadata.included_modules` no longer lists a module the concern declares in its own body, such as
  the `ClassMethods` a `self.included` hook extends the including class with, whether written `ClassMethods`,
  `self::ClassMethods` or in full.
  A module the concern brings in from elsewhere stays listed wherever the call is written.
  The `*Helper` includes of Phlex, ViewComponent and mailer units count only calls without a receiver or on
  `self`, outside a method body.
  A constant's name comes from its parsed path, so a comment inside a multi-line `Depot::` + `Weighable` path no
  longer ends up in the name.
  A qualified declaration such as `module Outer::Trackable` inside `module Outer` is read as `Outer::Trackable`, so
  its own `ClassMethods` stays out of `metadata.included_modules`.
  `extend self::ClassMethods` in a concern's body or `def self.included` no longer records an `extend` edge to a
  concern named `self`, and `include self::Helpers` there targets the concern's own `Helpers`.
  Where `self` is the including class or cannot be told (`base.class_eval { }`, `included do`, any other block,
  an instance method), a `self::` constant gives no edge and is not listed in `metadata.included_modules`.
