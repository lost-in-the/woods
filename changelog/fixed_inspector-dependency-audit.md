- Update the CI-only MCP Inspector pin to 2.12.0 and refresh its Vite lock
  resolution within Inspector's declared range. This resolves the currently
  reported TypeScript SDK and Vite audit findings. The Inspector and its Node
  dependencies are development tooling and are not shipped in the Ruby gem.
