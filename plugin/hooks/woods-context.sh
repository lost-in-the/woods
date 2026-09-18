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
  # Carry the producer status in-band: Bash 3.2 cannot wait on this
  # process-substitution PID. Cleanup finishes before the final status frame.
  printf '\n%s' "$status"
}
# Bash 3.2-compatible process substitution: buffer the bounded response until
# EOF and successful producer exit. Never forward a timed-out partial envelope.
exec 4< <(capture_response "$1")
supervisor=$!
trap 'kill -TERM "$supervisor" 2>/dev/null; exit 0' INT TERM
response=""
# <=2048 payload bytes + newline/status byte; one extra byte rejects overflow.
LC_ALL=C IFS= read -r -d '' -n 2051 response <&4
read_status=$?
exec 4<&-
if [ "$read_status" -ne 1 ]; then
  kill -TERM "$supervisor" 2>/dev/null || true
  exit 0
fi
case "$response" in *$'\n'0) response="${response%$'\n'0}" ;; *) exit 0 ;; esac
wait "$supervisor" 2>/dev/null || true
# One builtin write of an already complete <=2KiB envelope to the client pipe.
printf '%s' "$response"
exit 0
