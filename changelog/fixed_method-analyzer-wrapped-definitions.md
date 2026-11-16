- The self-map's method units now come from the method table, so they list every method Ruby defines.
  `private def`, `protected def`, `private_class_method def self.x` and `memoize def` were missing.
  So were the singleton copies of `module_function` methods (808 in Woods' own source).
  Visibility now follows Ruby: `private :name` after the definition, `initialize` and `respond_to_missing?` are
  private, and a `module_function`'s instance side is private.
  A method call graph keeps calls on absolute constants (`::Parser::CurrentRuby.parse`), which it dropped.
- `metadata.methods` lists definitions the method table skipped: those passed to any call (`memoize def total`),
  in a `begin` body, under `if`, `unless`, `elsif`, `else` or a modifier, and in a block of the body.
  An entry for a definition Ruby runs only on one path carries `candidate: "conditional"` or `candidate: "block"`.
  Entries the table already held keep their keys and values,
  unless a newly read later definition of the same name replaces one, as Ruby does.
- The self-map publishes each alternative body of one method in one file (an `if`, `elsif` and `else` each
  defining it) as its own unit, `Alt#pick [lib/alt.rb, occurrence 2]`, instead of writing them to one artifact
  and listing the shared identifier twice, which the index reader refused.
  The self-map writer now refuses two units that would share an artifact.
- A member `lookup` no longer answers one of several definitions of a method that the source does not order,
  such as the bodies of an `if` and its `else` or the branches of a `case`, as the method Ruby calls.
  It lists them under `candidates` with a statement that Woods cannot tell which one Ruby calls,
  unless a controller's `action_sources` names the one Ruby installed.
  The method table now also reads definitions in the branches of a `case` as `candidate: "conditional"`.
