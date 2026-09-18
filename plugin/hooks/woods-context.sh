#!/usr/bin/env bash
# Independently opt-in synchronous hints. The process deadline includes stdin,
# bundle startup, index/cache preparation, source verification and state I/O.
set -u
[ "${WOODS_HOOKS_DISABLED:-0}" = 1 ] && exit 0
[ "${WOODS_HOOK_CONTEXT_ENABLED:-0}" = 1 ] || exit 0
case "${1:-}" in SessionStart|PostToolUse) ;; *) exit 0 ;; esac
umask 077
record="$(mktemp "${TMPDIR:-/tmp}/woods-context.XXXXXX")" || exit 0
runner=""; timer=""
cleanup() {
  [ -z "$runner" ] || kill -KILL -- "-$runner" 2>/dev/null || true
  [ -z "$timer" ] || kill -KILL -- "-$timer" 2>/dev/null || true
  rm -f "$record"
}
trap cleanup EXIT
trap 'exit 0' INT TERM
exec 3<&0
set -m
command="${WOODS_HOOK_CONTEXT_COMMAND:-bundle exec woods-hook-context}"
( set -o pipefail; $command "$1" | head -c 2049 ) <&3 >"$record" 2>/dev/null &
runner=$!
( sleep 0.85; kill -KILL -- "-$runner" 2>/dev/null ) >/dev/null 2>&1 &
timer=$!
wait "$runner" 2>/dev/null
status=$?
kill -KILL -- "-$runner" 2>/dev/null || true
runner=""
kill -KILL -- "-$timer" 2>/dev/null || true
wait "$timer" 2>/dev/null || true
timer=""
set +m
# The installed helper writes a complete bounded JSON envelope. On timeout,
# missing older executables or malformed input, silence conveys no impact claim.
[ "$status" -eq 0 ] || exit 0
size="$(wc -c <"$record")"
[ "$size" -le 2048 ] || exit 0
cat "$record"
exit 0
