- Stop turning an interpolated partial name (`render "rows/#{kind}"`,
  `json.partial! "receipts/_#{order.kind}"`) into a render edge to a template
  that cannot exist. ERB, HAML, and jbuilder templates list it in
  `unresolved_partials` with kind `interpolation`, and drop it from
  `partials_rendered`.
