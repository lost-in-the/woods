- The incremental-equivalence oracle declares every field it does not compare once, in `IndexComparison::MASKS`,
  each with the reason a full and an incremental run may differ there; examples that compare a document themselves
  name a mask from the table instead of dropping keys. A red comparison ends with the masks in effect and prints
  their reasons (`WOODS_DIFF_MASKS=1` prints them on success too). A self-check changes one value at a time in a
  real index and requires a difference outside every mask and none inside one, and a budget fails any mask that
  hides a whole section or artifact, or over a tenth of a document, without declaring itself wide.
  Opt-in masks are probed too, each under the default set plus itself, and a declared mask no probe reaches fails.
