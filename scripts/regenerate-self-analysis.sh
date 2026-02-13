#!/bin/bash
changed_files=$(git diff --cached --name-only -- 'lib/')
if [ -n "$changed_files" ]; then
  bundle exec rake codebase_index:self_analyze
  git add tmp/codebase_index_self/ docs/self-analysis/
fi
