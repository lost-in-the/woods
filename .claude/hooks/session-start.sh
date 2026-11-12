#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: install the development
# bundle so bin/rspec, bin/rubocop and the woods-self MCP server work from the
# first turn. A fresh cloud container has Ruby but none of the gems.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}"

# Gems install outside the checkout, so the record of the last successful
# install lives with them and disappears when they do.
hashes="$(ruby -e 'print Gem.dir')/.woods-session-start.sha256"
if ! sha256sum --check --status "$hashes" 2>/dev/null; then
  rm -f "$hashes"
  bundle install --quiet
  sha256sum .claude/hooks/session-start.sh Gemfile woods.gemspec lib/woods/version.rb > "$hashes" || rm -f "$hashes"
fi
