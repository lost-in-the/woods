- The path-free container entry no longer serves a session in a linked worktree the mounted checkout's index when
  no mount map is set. It hands the server what the session's checkout is, with no path in it
  (`--client-identity main|linked:HEAD:branch`, `WOODS_MCP_CLIENT_IDENTITY`), and the server refuses a different
  worktree kind, HEAD or branch with the mismatch message, naming `WOODS_MCP_CLIENT_ROOT_MAP` and
  `--allow-mismatch`. A session in the mounted checkout still starts, with or without uncommitted changes.
  An identity that agrees is reported as agreeing (`client_identity_agrees` in `woods_status`, and the warning),
  and one with neither HEAD nor branch, as sent from outside any git checkout, counts as no identity.
