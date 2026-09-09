#!/usr/bin/env bash
# Woods SessionStart hook (#280): say so when the published generation is
# older than the last commit. Stdout from a SessionStart hook is added to
# the session context, so the agent sees the warning before it trusts the
# index.
#
# This check only compares two commit-adjacent timestamps: the generation's
# `updated_at` and `git log -1`'s commit time. It says nothing about
# uncommitted edits (the index can be stale against a dirty working tree
# with no stale commit to detect) or about a checkout sitting on an older
# commit than the one that produced the generation (the timestamp comparison
# can read as fresh there even though the code and the index disagree). Read
# a quiet run as "not behind the last commit," not as "definitely current."
#
# Opt-in: shipped disabled. Nothing prints until WOODS_HOOKS_ENABLED=1 is
# set; WOODS_HOOKS_DISABLED=1 turns it back off without touching that
# setting.
set -u

[ "${WOODS_HOOKS_DISABLED:-0}" = "1" ] && exit 0
[ "${WOODS_HOOKS_ENABLED:-0}" = "1" ] || exit 0

payload="$(cat)"

field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r ".$1 // empty"
  elif command -v ruby >/dev/null 2>&1; then
    printf '%s' "$payload" | ruby -rjson -e '
      value = JSON.parse($stdin.read)
      ARGV[0].split(".").each { |key| value = value.is_a?(Hash) ? value[key] : nil }
      print value.to_s' -- "$1"
  else
    printf ''
  fi
}

cwd="$(field cwd)"
[ -z "$cwd" ] && exit 0

# Same no-boot resolution the PostToolUse hook and woods:watch_status use:
# WOODS_OUTPUT overrides outright, otherwise tmp/woods under cwd.
configured_output="${WOODS_OUTPUT:-tmp/woods}"
case "$configured_output" in
  /*) tmp_dir="$configured_output" ;;
  *) tmp_dir="$cwd/$configured_output" ;;
esac

marker="$tmp_dir/generation.json"
[ -f "$marker" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  updated="$(jq -r '.updated_at // empty' "$marker")"
  number="$(jq -r '.number // empty' "$marker")"
elif command -v ruby >/dev/null 2>&1; then
  updated="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["updated_at"].to_s' -- "$marker")"
  number="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0]))["number"].to_s' -- "$marker")"
else
  exit 0
fi
[ -z "$updated" ] && exit 0

last_commit="$(git -C "$cwd" log -1 --format=%cI 2>/dev/null)"
[ -z "$last_commit" ] && exit 0

stale=0
if command -v ruby >/dev/null 2>&1; then
  ruby -rtime -e 'exit(Time.parse(ARGV[0]) < Time.parse(ARGV[1]) ? 1 : 0)' -- "$updated" "$last_commit" || stale=1
elif date -d "$updated" +%s >/dev/null 2>&1; then
  [ "$(date -d "$updated" +%s)" -lt "$(date -d "$last_commit" +%s)" ] && stale=1
fi

if [ "$stale" = "1" ]; then
  echo "Woods index is stale: generation ${number:-?} was published at $updated, before the last commit at $last_commit." \
       "Run bin/rails woods:incremental (or start bin/rails woods:watch) before trusting woods answers."
fi
exit 0
