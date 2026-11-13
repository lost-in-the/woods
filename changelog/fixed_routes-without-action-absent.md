- `lookup` no longer shows an empty `routes_without_action` for a controller whose every route has an action.
  A key the unit file itself carries is dropped when the generation flags nothing, a blank action name in
  the graph analysis is not listed, and the Markdown, Claude and plain formats skip an empty metadata object as
  they skip an empty list.
