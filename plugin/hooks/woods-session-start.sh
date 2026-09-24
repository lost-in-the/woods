#!/usr/bin/env bash
# Opt-in, bounded source-content verification through the application's rake
# command. The status task has no Rails environment prerequisite; Docker-only
# installations do not need the Woods gem or an application bundle on the host.
set -u

[ "${WOODS_HOOKS_DISABLED:-0}" = "1" ] && exit 0
[ "${WOODS_HOOKS_ENABLED:-0}" = "1" ] || exit 0
payload="$(cat)"
field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -r --arg name "$2" '.[$name] // empty' 2>/dev/null
  elif command -v ruby >/dev/null 2>&1; then
    printf '%s' "$1" | ruby -EUTF-8:UTF-8 -rjson -e 'print JSON.parse($stdin.read).fetch(ARGV[0], "")' -- "$2" 2>/dev/null
  fi
}
cwd="$(field "$payload" cwd)"
[ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
configured_output="${WOODS_OUTPUT:-tmp/woods}"
case "$configured_output" in
  /*) output_dir="$configured_output" ;;
  *) output_dir="$cwd/$configured_output" ;;
esac
[ -f "$output_dir/generation.json" ] || exit 0
if command -v jq >/dev/null 2>&1; then
  encoded="$(jq -nr --arg output "$configured_output" '{output:$output,mode:"quick"} | @base64')"
elif command -v ruby >/dev/null 2>&1; then
  encoded="$(ruby -EUTF-8:UTF-8 -rjson -rbase64 -e 'print Base64.strict_encode64(JSON.generate(output: ARGV[0], mode: "quick"))' -- "$configured_output" 2>/dev/null)" || {
    echo 'Woods source freshness is unknown: hook options could not be encoded. Inspect woods_status.'
    exit 0
  }
else
  exit 0
fi

record="$(mktemp "${TMPDIR:-/tmp}/woods-source-status.XXXXXX")" || exit 0
runner=""; timer=""
cleanup() {
  [ -z "$runner" ] || kill -KILL -- "-$runner" 2>/dev/null || true
  [ -z "$timer" ] || kill -TERM -- "-$timer" 2>/dev/null || true
  rm -f "$record"
}
trap cleanup EXIT
trap 'exit 0' INT TERM
# Ten seconds includes command startup; the shared content verifier itself has
# a 250ms scan budget. A client hook timeout alone is not a process deadline.
set -m
rake="${WOODS_HOOK_RAKE:-bundle exec rake}"
( cd "$cwd" || exit 1; exec $rake "woods:source_status[$encoded]" ) >"$record" 2>/dev/null &
runner=$!
( sleep 10; kill -TERM -- "-$runner" 2>/dev/null; sleep 1; kill -KILL -- "-$runner" 2>/dev/null ) >/dev/null 2>&1 &
timer=$!
wait "$runner" 2>/dev/null
result=$?
kill -KILL -- "-$runner" 2>/dev/null || true
runner=""
kill -TERM -- "-$timer" 2>/dev/null || true
wait "$timer" 2>/dev/null || true
timer=""
set +m
if [ "$result" -ne 0 ]; then
  echo 'Woods source freshness is unknown: source verification was unavailable or exceeded its deadline. Inspect woods_status; use woods-extract full for a fresh capture.'
  exit 0
fi
status="$(tail -n 1 "$record")"
state="$(field "$status" state)"
case "$state" in
  current) ;;
  drifted) echo 'Woods source freshness is drifted: indexed application inputs differ from the working tree. Run woods-extract full, or inspect woods_status before choosing a targeted refresh.' ;;
  *) echo 'Woods source freshness is unknown: this generation lacks complete verified source evidence. Inspect woods_status; use woods-extract full for a fresh capture.' ;;
esac
exit 0
