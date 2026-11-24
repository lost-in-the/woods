- `metadata.methods` gains entries for definitions under conditionals, in blocks and passed to calls such as
  `memoize`, and a `candidate` key on the entries Ruby runs only on one path.
  A reader that treats every entry as a definite method should skip entries that have `candidate`.
  Units in an existing index gain the entries when each is re-extracted; run `woods:extract` to add them all.
