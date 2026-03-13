#!/bin/bash
changed_files=$(git diff --cached --name-only -- 'lib/')
if [ -n "$changed_files" ]; then
  bundle exec rake woods:self_analyze
  git add tmp/woods_self/ docs/self-analysis/
fi
