- `metadata.methods` now publishes the kind and visibility Ruby reports for each definition.
  `initialize`, `initialize_copy`, `initialize_dup`, `initialize_clone` and `respond_to_missing?` are private
  instance methods even under a bare `public`.
  `module_function :name` after the definition makes the named methods `module_function` entries, as the bare and
  inline forms already did.
  `private_class_method def self.x` records the method (it was missing), `public_class_method` is honored, and a
  later `public :name` or `protected :name` on a module function splits it into an `instance` and a `singleton`
  entry.
  The table now applies the body's statements in order: a later definition replaces the earlier one on the same
  side, and `module_function :a` replaces an earlier `def self.a`, so no superseded definition is left beside the
  live one for a member lookup to choose.
  A spec evaluates each covered form and compares the table, visibility and definition line, with Ruby's own answer.
