- `metadata.methods` now publishes the kind and visibility Ruby reports for each definition.
  `initialize`, `initialize_copy`, `initialize_dup`, `initialize_clone` and `respond_to_missing?` are private
  instance methods even under a bare `public`.
  `module_function :name` after the definition makes the named methods `module_function` entries, as the bare and
  inline forms already did.
  `private_class_method def self.x` records the method (it was missing), `public_class_method` is honored, and a
  later `public :name` or `protected :name` on a module function splits it into an `instance` and a `singleton`
  entry.
  A spec evaluates each covered form and compares the table with Ruby's own answer.
