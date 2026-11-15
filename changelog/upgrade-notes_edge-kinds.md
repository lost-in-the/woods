- Four kinds of dependency edge changed, so a program that walks the dependency graph or a unit's `dependencies`
  by `via` finds different edges after upgrading.
  - **Migrations and database views** point at `database_table` units: `via: migrates` from a migration,
    `via: view_source` from a view.
    The `via: table_name` and `via: reference` edges to a model remain only where a model owns the table today.
    Follow `migrates` or `view_source` to reach a table.
  - **Events** depend on the classes that publish and subscribe to them (`via: published_by`, `via: subscribed_by`).
    The `code_reference` edges from event units are gone.
  - **HTTP calls** from services and jobs to the symbolic `http_api` target are `via: external_call`, not
    `code_reference`.
  - **Mixins** written as a constant in `include`, `extend` or `prepend` are `via: include` or `via: extend`, not
    `code_reference`, for every unit type the source-reference pass covers.
  A program that found these relationships through `code_reference` or `table_name` should filter on the new kinds.
  Run one full `woods:extract` after upgrading so every unit carries the new edges.
