- Three tool calls return less by default than in 2.1, and each says so in its answer.
  An agent follows the paging the answer describes; a program that read the whole result from one call should
  page or raise the limit.
  - **`lookup`** answers a full rendering longer than 40,000 characters in pages, each naming the next `page` and
    its `answer_id`.
    Pass `max_chars`, or set `WOODS_MCP_LOOKUP_MAX_CHARS` (`0` turns paging off).
  - **`domain_clusters`** returns the 20 largest clusters and at most 50 members, entry points and boundary edges
    each, with `has_more` and `*_omitted` counts.
    Pass `limit`, `offset` and `member_limit`, or set `WOODS_DOMAIN_CLUSTERS_LIMIT` and
    `WOODS_DOMAIN_CLUSTERS_MEMBER_LIMIT`.
    `graph_analysis.json` still holds every cluster.
  - **`console_sql`** returns at most 100 rows without `limit`, clamps `limit` to 1000, and reports truncation in
    `completeness`.
    Set `console_sql_default_limit` and `console_sql_max_limit` to change both.
