- Resolve a relative view partial (`render 'show'`) through the rendering
  controller's runtime `_prefixes` when the template's own directory has no
  such partial, then through `application/`, as Rails does. Incremental limit:
  changing a controller's superclass does not re-extract the templates under
  it; edit the template or run a full extraction.
