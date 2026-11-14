- `metadata.methods` now publishes the kind and visibility Ruby reports for each definition.
  `initialize`, `initialize_copy`, `initialize_dup`, `initialize_clone` and `respond_to_missing?` are private
  instance methods even under a bare `public`.
  `module_function :name` after the definition makes the named methods `module_function` entries, as the bare and
  inline forms already did.
  `private_class_method def self.x` records the method (it was missing), `public_class_method` is honored, and a
  later `public :name` or `protected :name` on a module function splits it into an `instance` and a `singleton`
  entry.
  A `def` written inline after `private`, `protected`, `public`, `private_class_method` or `public_class_method` under
  a bare `module_function` is now read as a module function, then changed by that call.
  `private_class_method def x` there was an `instance` entry reading public and is now private on both sides, and
  `private def x` keeps its public singleton copy.
  Such an inline `def` passes its name to the call as Ruby does, so `private_class_method def a` beside an earlier
  `def self.a` now marks `self.a` private instead of the new instance method, and `private def self.b` marks an
  instance method `b`.
  A `def self.x` inside `class << self` is left out instead of replacing the owner's own `self.x`: Ruby defines it
  on the singleton class's singleton class.
  The same holds for a `def` in a `class << self` nested in another `class << self` or in a `class_methods do` block.
  A `def self.x` under a bare `module_function` is a `singleton` entry, not a `module_function` one: Ruby defines
  no instance method for it.
  The table now applies the body's statements in order: a later definition replaces the earlier one on the same
  side, and `module_function :a` replaces an earlier `def self.a`, so no superseded definition is left beside the
  live one for a member lookup to choose.
  A spec evaluates each covered form and compares the table, visibility and definition line, with Ruby's own answer.
  A `def self.x` inside `class_methods do` is left out too: it defines a method of the ClassMethods module, which an
  includer never receives, and its entry sat beside the sibling `def x` as a second `singleton` entry.
