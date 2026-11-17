- Units whose source writes a compact declaration inside its own namespace module change identifier.
  `module Billing; class Billing::Invoice` is now `Billing::Invoice` instead of `Billing::Billing::Invoice`.
  An incremental run renames only the files it re-extracts.
  Run `woods:extract` once after upgrading to rename every affected unit.
  Edges from other units already name the real constant, and resolve once its unit carries that name.
