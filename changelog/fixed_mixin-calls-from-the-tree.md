- Concern `include`/`extend` edges and `metadata.included_modules`, and the `*Helper` includes of Phlex,
  ViewComponent and mailer units, now come from real `include`/`extend` calls with constant arguments in the
  Prism tree.
  A comment such as "the include of this module" no longer produces a concern dependency named `of`, and a
  string, heredoc, method name or `extend self` declares nothing.
  Every constant of `include A, B` and of a multi-line argument list is now read, not only the first.
  A concern's `metadata.included_modules` lists only calls without a receiver or on `self`, outside a method
  body: `base.extend ClassMethods` or `base.include A` in `self.included` acts on the including class and is no
  longer listed there.
  Those hook-form calls still give their `include` and `extend` dependency edges.
