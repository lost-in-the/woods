- Add [Compatibility](docs/COMPATIBILITY.md), the written promise behind the version number.
  Configuration, environment variables, rake tasks, executables, generators, MCP tool names and parameters,
  the Ruby entry points and the index envelope stay stable within a major release.
  Index metadata, edge kinds, tool output and defaults may change in a minor release, with an upgrade note when a
  caller would notice, and a refusal that prevents a wrong answer must name its remedy.
  Deprecated surfaces keep working until the next major release.
  The page replaces the shorter compatibility section of the published index layout.
