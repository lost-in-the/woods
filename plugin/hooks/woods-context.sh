#!/usr/bin/env bash
# Independently opt-in synchronous hints. The process deadline includes stdin,
# bundle startup, index/cache preparation, source verification and state I/O.
set -u
[ "${WOODS_HOOKS_DISABLED:-0}" = 1 ] && exit 0
[ "${WOODS_HOOK_CONTEXT_ENABLED:-0}" = 1 ] || exit 0
case "${1:-}" in SessionStart|PostToolUse) ;; *) exit 0 ;; esac
exec 3<&0
capture_response() {
  runner=""; timer=""
  cleanup() {
    [ -z "$runner" ] || kill -KILL -- "-$runner" 2>/dev/null || true
    [ -z "$timer" ] || kill -KILL -- "-$timer" 2>/dev/null || true
  }
  trap cleanup EXIT
  trap 'exit 1' INT TERM
  set -m
  command="${WOODS_HOOK_CONTEXT_COMMAND:-bundle exec woods-hook-context}"
  ( $command "$1" ) <&3 2>/dev/null &
  runner=$!
  ( sleep 0.85; kill -KILL -- "-$runner" 2>/dev/null ) >/dev/null 2>&1 &
  timer=$!
  wait "$runner" 2>/dev/null
  status=$?
  cleanup
  wait "$timer" 2>/dev/null || true
  runner=""; timer=""
  exit "$status"
}
# Bash 3.2-compatible process substitution: buffer the bounded response until
# EOF and successful producer exit. Never forward a timed-out partial envelope.
exec 4< <(capture_response "$1")
supervisor=$!
trap 'kill -TERM "$supervisor" 2>/dev/null; exit 0' INT TERM
response=""
LC_ALL=C IFS= read -r -d '' -n 2049 response <&4
read_status=$?
exec 4<&-
wait "$supervisor" 2>/dev/null
status=$?
[ "$status" -eq 0 ] && [ "$read_status" -eq 1 ] || exit 0
# One builtin write of an already complete <=2KiB envelope to the client pipe.
printf '%s' "$response"
exit 0
