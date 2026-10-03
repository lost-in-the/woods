- Extract `.jbuilder` templates under `app/views` as `view_template` units with
  `template_engine: jbuilder`. Partials come from `json.partial!` and from the
  `partial:` option of any `json.*` call. A partial whose path is built at
  runtime (a helper call or an object) is listed in the new
  `unresolved_partials` metadata instead of becoming an edge.
