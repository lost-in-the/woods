- Factories declared with `parent:` or nested in another factory now model the parent's class, across files, and a leading `::` on `class:` is dropped, so `factory_for` edges point at the real model.
  A nested factory also records its enclosing factory as `parent_factory`.
