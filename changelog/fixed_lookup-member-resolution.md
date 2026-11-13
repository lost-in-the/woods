- `lookup` of `Owner#method` / `Owner.method` now answers the definition Ruby calls, read through the owner's
  published superclass chain, and says so where the index cannot tell. A unit that inherits a superclass's
  override of an inlined concern's method answered the concern's method; the parent's own definition is now the
  answer, named in `inherited_from` (`member_of` stays the asked owner). Several inlined concerns defining one name
  answered the later line, which for a model is the concern Ruby reaches last; a model's concerns are now ranked in
  their published `included_modules` order, while a controller's, sorted by name, are listed as `candidates` with
  a statement that Woods cannot tell which one Ruby calls. A concern a class prepends now outranks its own body,
  and a `prepend` of a module whose source is not inlined adds a `caveats` entry, as does an inlined-concern answer
  under an unpublished parent (an abstract `ApplicationRecord`) when no read unit's body is shown, by a Prism
  walk, to include that concern, since the parent's own definition could then come first. A concern unit no
  longer answers `Concern.x` for a definition in its own `class_methods do` block; the not-found answer says it
  is a class method the concern gives to its includers. The `statement` now says how the answer was established
  (own body, inherited, inlined, prepended).
