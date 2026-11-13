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
  A class nested in its own superclass's body, published as its own lexical range (a nested job or PORO), answered
  the enclosing class's definition of the name; it now answers its own, and inherits only what it does not define.
  A name a class body defines by a call rather than a `def` (`attr_reader`, `alias_method`, `delegate`,
  `define_method`, ...) answered a superclass's `def` as inherited; that level's call is now the answer, under
  `defined_by`. A call Woods does not know that carries the name (a base class's DSL) now gives an answer that
  says Woods cannot tell which definition Ruby calls and lists `candidates`, the call first and then every
  definition past it, instead of presenting the superclass's. Such a call with no other definition of the name on
  that side leaves the member `not_found`, as before, and the message names the call.
  An answer from such a call states the visibility Ruby gives it where Ruby fixes it (`delegate` public unless
  `private: true`, an alias that of the method it copies), and no longer reads "a instance method" without one.
  Common Rails calls are read by the side they define: associations, `attribute`, `alias_attribute` and
  `store_accessor` define instance methods, ranked where Ruby ranks the modules they define into; `scope` a class
  method; `class_attribute` both sides, as its options allow; and `serialize`, `has_secure_token`, `layout`,
  `helper` and `rescue_from` define none of the names they carry.
  A `delegate` or `alias_method` passed to `private` (`private delegate :x, to: :y`) is answered as private, as
  Ruby makes it, not as public or as the aliased method's visibility.
  An answer from `scope` now states its visibility (public, unless a later `private_class_method` names it), as the
  other Rails calls' answers do, in the owner's own body and in a superclass.
  A Rails call names only the methods it defines: an association, `attribute` or `alias_attribute` its first
  argument (not `attribute`'s type), and `store_accessor` each key under its `prefix:` and `suffix:`.
  `accepts_nested_attributes_for :items` after `has_many :items` no longer turns `Owner#items` into a cannot-tell
  answer: it defines `items_attributes=` only. `composed_of` and `enum` (its value scopes and `value?`/`value!`)
  are read as definers, and `delegate_missing_to`, `attr_readonly`, `normalizes`, `encrypts`, `default_scope`,
  `queue_as`, `retry_on` and `discard_on` as calls that define none of the names they carry.
  A `store_accessor` or `enum` option that is not a literal no longer hides the names the call may define: a
  superclass method such as `lamp_glow` under `prefix: SOME_CONSTANT` is a cannot-tell answer, not a confident one.
  A candidates answer no longer says "the definition above overrides" a farther definition.
