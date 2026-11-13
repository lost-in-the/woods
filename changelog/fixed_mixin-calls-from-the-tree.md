- Concern `include`/`extend` edges and `metadata.included_modules`, and the `*Helper` includes of Phlex,
  ViewComponent and mailer units, now come from real `include`/`extend` calls with constant arguments in the
  Prism tree.
  A comment such as "the include of this module" no longer produces a concern dependency named `of`, and a
  string, heredoc, method name or `extend self` declares nothing.
  Every constant of `include A, B` and of a multi-line argument list is now read, not only the first.
  Only a call without a receiver or on `self`, outside a method body, declares a mixin of the unit.
  `base.extend ClassMethods` or `base.include A` in `self.included` acts on the including class: it no longer
  lists `ClassMethods` or `A` in `metadata.included_modules` and no longer records an `include` or `extend` edge.
  Run a full extraction to drop the edges an older index holds.
