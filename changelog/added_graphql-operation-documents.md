- **Client GraphQL operation documents are indexed (#675).** A new `graphql_operation`
  unit type covers `.graphql` / `.gql` files under `config.graphql_document_paths`
  (default `app/javascript/**/*.{graphql,gql}` and `app/frontend/**/*.{graphql,gql}`):
  one unit per named operation and per fragment, identified as `gql:<Name>`. Each
  unit carries edges to the resolver, mutation and type units it selects
  (`root_field`, `type_reference`) and to the fragments it spreads
  (`fragment_spread`), so `dependents` of a mutation or type lists the client
  documents that use it. Selections the schema no longer has are recorded in
  `metadata.unknown_fields`, never as edges. Documents are parsed with the
  graphql gem when the host loads it; without it the family is skipped with a
  logged note. Incremental runs and the watch daemon re-run the family on a
  document change and on any `.rb` change under `app/graphql`. The dispatch rule
  fingerprint changes, so run one full extraction after upgrading.
