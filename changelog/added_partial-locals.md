- ERB view templates now record partial locals (woods#798):
  - `metadata.partial_renders` on every template: each literal partial render with the partial name, the render edge's `target`, the `locals` keys it passes, the `implicit_local` that an `object:`/`collection:` render defines (from `as:` or the partial's name), `dynamic_locals` when a key cannot be named, and the `line`.
  - On partials, `metadata.locals_read`: the bare identifiers and literal `local_assigns` keys the template reads. The list is lexical and wide, because a helper call reads the same as a local.
  - `metadata.locals_read_dynamic`: set when locals are reached by a computed key or through `binding`.
  - `metadata.locals_declared`: the strict locals a `<%# locals: (...) %>` magic comment declares.

  All four are read from the template's syntax tree, so markup and comments never contribute. Haml and Jbuilder templates publish none of these keys yet; an absent key means not read, not none.
