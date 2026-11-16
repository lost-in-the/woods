- A compact class or module declaration inside its own namespace module is named as Ruby names it.
  `module Billing; class Billing::Invoice` was published as `Billing::Billing::Invoice`, a constant that does not exist.
  A qualified declaration's first constant is now read as the innermost module's own constant when the file declares
  it, else as an enclosing module of that name.
  Otherwise the declaration stays nested, since a nearer constant may come from another file:
  `module Billing; class Invoice::Line` stays `Billing::Invoice::Line`.
  A declaration written `class ::Billing::Refund` is now read, with its body, instead of skipped.
  Source-named units (services, POROs, libraries, concerns and the other source-derived types) take the new names.
  So do method table owners, `lookup Owner#method` on any unit whose source is written this way, and the self-map.
  The mixin scan of concerns, mailers and components (their `include`, `extend` and `prepend` calls) changes too.
  It read a nested prefix as a sibling or top-level module the file declares:
  `class Invoice; end; module Billing; class Invoice::Line` was `Invoice::Line` there, and is `Billing::Invoice::Line`.
