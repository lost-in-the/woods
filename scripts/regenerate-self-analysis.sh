#!/bin/bash
set -euo pipefail

# Refresh local diagnostics for staged lib/ changes; never stage generated output.
cd "$(git rev-parse --show-toplevel)"
changed_files=$(git diff --cached --name-only -- 'lib/')
if [ -n "$changed_files" ]; then
  bin/rake woods:self_analyze
fi
