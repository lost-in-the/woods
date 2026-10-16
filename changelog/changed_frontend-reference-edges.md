- Components and view templates now link to the JavaScript modules they name.
  `x-data="name"` / `x-data="name(...)"` resolves to the Alpine module
  (`via: :alpine_data`), each name in `data-controller="a b"` to its Stimulus
  controller (`via: :stimulus_controller`), and a custom element tag such as
  `<x-shipment-card>` to the Stencil component or defined element
  (`via: :custom_element`). The former dangling `:stimulus_controller` edges
  (`via: :html_attribute`) are gone: a name no module registers produces no
  edge and is listed in `metadata.unresolved_frontend_references`. An
  anonymous Alpine scope (`x-data`, `x-data="true"`, an inline object) names
  nothing and is not listed. Incremental
  runs re-run `js_modules` wholesale on any module change and re-run the
  components and templates only when a registered name appeared, moved or
  vanished.
