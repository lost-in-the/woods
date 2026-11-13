- `metadata.methods` now publishes the kind and visibility Ruby reports for each definition.
  `initialize`, `initialize_copy`, `initialize_dup`, `initialize_clone` and `respond_to_missing?` are private
  instance methods even under a bare `public`.
  `module_function :name` after the definition makes the named methods `module_function` entries, as the bare and
  inline forms already did.
  `private_class_method def self.x` records the method (it was missing), `public_class_method` is honored, and a
  later `public :name` or `protected :name` on a module function splits it into an `instance` and a `singleton`
  entry.
  A spec evaluates each covered form and compares the table with Ruby's own answer.
  A `def` written inline after `private`, `protected`, `public`, `private_class_method` or `public_class_method` under
  a bare `module_function` is now read as a module function, then changed by that call.
  `private_class_method def x` there was an `instance` entry reading public and is now private on both sides, and
  `private def x` keeps its public singleton copy.
  A `def self.x` under a bare `module_function` is a `singleton` entry, not a `module_function` one: Ruby defines
  no instance method for it.
