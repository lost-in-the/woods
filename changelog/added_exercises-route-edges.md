- Link feature, system and request tests to the routes they navigate: `visit`, `get`, `post`, `put`, `patch`, `delete` and `head` with a route helper or a literal path become `exercises_route` edges to route units, resolved from the live route set, and `routes_exercised` metadata.
  A `type: :request` declared on the first example group now sets `test_type`.
