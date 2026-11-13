- `lookup` of `Owner#method` / `Owner.method` now answers the definition Ruby calls, read through the owner's
  published superclass chain, and says so where the index cannot tell. A unit that inherits a superclass's
  override of an inlined concern's method answered the concern's method; the parent's own definition is now the
  answer, named in `inherited_from` (`member_of` stays the asked owner). Several inlined concerns defining one name
  answered the later line, which for a model is the concern Ruby reaches last; a model's concerns are now ranked in
  their published `included_modules` order, while a controller's, sorted by name, are listed as `candidates` with
  a statement that Woods cannot tell which one Ruby calls. A concern a class prepends now outranks its own body,
  and a `prepend` of a module whose source is not inlined, or a chain that stops at an unpublished parent under an
  inlined-concern answer, adds a `caveats` entry. A concern unit no longer answers `Concern.x` for a definition in
  its own `class_methods do` block; the not-found answer says it is a class method the concern gives to its
  includers. The `statement` now says how the answer was established (own body, inherited, inlined, prepended).
  A class nested in its own superclass's body, published as its own lexical range (a nested job or PORO), answered
  the enclosing class's definition of the name; it now answers its own, and inherits only what it does not define.
  A name a class body defines by a call rather than a `def` (`attr_reader`, `alias_method`, `delegate`,
  `define_method`, ...) answered a superclass's `def` as inherited; that level's call is now the answer, under
  `defined_by`. A call Woods does not know that carries the name (a base class's DSL) now gives an answer that
  names the call and says Woods cannot tell which definition Ruby calls, instead of presenting the superclass's.
