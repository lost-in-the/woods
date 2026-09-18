#!/usr/bin/env bash
# Opt-in refresh dispatcher. Each edit is durable until its task succeeds.
# See docs/WATCH_DAEMON.md for retry, daemon deferral and Docker transport.
set -u
umask 077
[ "${WOODS_HOOKS_DISABLED:-0}" = 1 ] && exit 0
[ "${WOODS_HOOKS_ENABLED:-0}" = 1 ] || exit 0

client="${1:-}"
hook_dir="${BASH_SOURCE[0]%/*}"
# Preserve raw bytes until JSON validation: Bash command substitution silently
# removes NUL bytes and could turn a malformed path into a different valid one.
input_file="$(mktemp "${TMPDIR:-/tmp}/woods-hook-input.XXXXXX")" || exit 0
trap 'rm -f "$input_file"' EXIT
trap 'exit 143' TERM INT
head -c 1048577 >"$input_file" || exit 0
payload_bytes="$(wc -c <"$input_file")"
[ "$payload_bytes" -le 1048576 ] || { printf '[Woods hooks] Oversized edit event; no refresh queued.\n' >&2; exit 0; }
if command -v jq >/dev/null 2>&1; then
  payload="$(jq -c --arg client "$client" -f "$hook_dir/adapters/normalize.jq" <"$input_file" 2>/dev/null)" || {
    printf '[Woods hooks] Unsupported or malformed edit event; no refresh queued.\n' >&2; exit 0;
  }
elif command -v ruby >/dev/null 2>&1; then
  payload="$(ruby "$hook_dir/adapters/normalize.rb" "$client" <"$input_file")" || exit 0
else
  printf '[Woods hooks] jq or Ruby is required; no refresh queued.\n' >&2
  exit 0
fi
rm -f "$input_file"
trap - EXIT TERM INT
field() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -ej '.root'
  else
    printf '%s' "$payload" | ruby -rjson -e 'print JSON.parse($stdin.read).fetch("root")'
  fi
}
cwd="$(field; printf .)"
cwd="${cwd%.}"
cwd="${cwd%/}"
[ -n "$cwd" ] || exit 0
[ -d "$cwd" ] || exit 0
configured_output="${WOODS_OUTPUT:-tmp/woods}"
case "$configured_output" in /*) tmp_dir="$configured_output" ;; *) tmp_dir="$cwd/$configured_output" ;; esac
[ -f "$tmp_dir/generation.json" ] || exit 0
source "$hook_dir/woods-input-rules.sh" || exit 0
# Validate every member before publishing the event. Missing/deleted paths are
# allowed; symlink components are deliberately unsupported, including escapes.
event_fields() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j '.events[] | .operation,"\u0000",.path,"\u0000"'
  else
    printf '%s' "$payload" | ruby -rjson -e 'JSON.parse($stdin.read).fetch("events").each { |e| print e.fetch("operation"), "\0", e.fetch("path"), "\0" }'
  fi
}
relevant=0
invalid=0
while IFS= read -r -d '' operation && IFS= read -r -d '' file; do
  case "$file" in "$cwd"/*) rel="${file#"$cwd"/}" ;; /*) invalid=1; break ;; *) rel="$file" ;; esac
  case "/$rel/" in */../*|*/./*|*//* ) invalid=1; break ;; esac
  parent="$cwd/$rel"
  while [ "$parent" != "$cwd" ]; do
    if [ -L "$parent" ]; then invalid=1; break; fi
    parent="${parent%/*}"
  done
  [ "$invalid" = 0 ] || break
  [ "$(woods_input_action "$rel")" = ignore ] || relevant=1
done < <(event_fields)
if [ "$invalid" = 1 ]; then
  printf '[Woods hooks] Foreign, escaping or symlinked edit path; no refresh queued.\n' >&2
  exit 0
fi
[ "$relevant" = 1 ] || exit 0

log="$tmp_dir/hook.log"
queue="$tmp_dir/hook-pending"
run_lock="$tmp_dir/hook.lock"
run_lock_dir="$tmp_dir/hook.lock.d"
mkdir -p "$queue" || exit 0
# Files are immutable once published. A killed worker never destroys its batch.
enqueue() {
  event="$queue/$$.$RANDOM.$RANDOM"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg path "$1" '{path:$path,operation:"update"}' >"$event.tmp" || return 1
  else
    ruby -rjson -e 'puts JSON.generate(path: ARGV[0], operation: "update")' -- "$1" >"$event.tmp" || return 1
  fi
  mv "$event.tmp" "$event.json"
}
# One immutable file keeps a multi-file event indivisible across crashes.
event="$queue/$$.$RANDOM.$RANDOM"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$payload" | jq -c --arg root "$cwd" '.events | map(.path |= (if startswith($root + "/") then ltrimstr($root + "/") else . end))' >"$event.tmp" || exit 0
else
  printf '%s' "$payload" | ruby -rjson -e 'v = JSON.parse($stdin.read); puts JSON.generate(v.fetch("events").map { |e| e.merge("path" => e.fetch("path").delete_prefix(ARGV.fetch(0) + "/")) })' -- "$cwd" >"$event.tmp" || exit 0
fi
mv "$event.tmp" "$event.json" || exit 0

# A private deadline applies even when the client backgrounds async hooks.
budget="${WOODS_HOOK_TIMEOUT_SECONDS:-600}"
case "$budget" in ''|*[!0-9]*|0) printf 'Invalid WOODS_HOOK_TIMEOUT_SECONDS; queued work retained.\n' >>"$log"; exit 0 ;; esac
[ "$budget" -le 3600 ] || exit 0
started=$SECONDS
have_flock() { command -v flock >/dev/null 2>&1; }
acquire() {
  if have_flock; then
    exec 8>"$run_lock"
    flock -n 8
  else
    if ! mkdir "$run_lock_dir" 2>/dev/null; then
      owners=("$run_lock_dir"/owner-*)
      [ "${#owners[@]}" -le 1 ] || return 1
      if [ "${#owners[@]}" -eq 1 ]; then
        owner="${owners[0]##*/owner-}"
        # Never steal a live owner's lease solely because its mtime is old.
        case "$owner" in *[!0-9]*) return 1 ;; esac
        kill -0 "$owner" 2>/dev/null && return 1
        # Only the reclaimer that removes this marker may replace the directory.
        # Another reclaimer may already have created a new, still-empty lock.
        rm "${owners[0]}" 2>/dev/null || return 1
        rmdir "$run_lock_dir" 2>/dev/null || return 1
      else
        # Compatibility recovery for an old empty mkdir lock after a crash.
        mtime="$(stat -c %Y "$run_lock_dir" 2>/dev/null || stat -f %m "$run_lock_dir" 2>/dev/null)"
        [ -n "$mtime" ] || return 1
        now="$(date +%s)"
        [ "$((now - mtime))" -gt "${WOODS_HOOK_LOCK_STALE_SECONDS:-1800}" ] || return 1
        rmdir "$run_lock_dir" 2>/dev/null || return 1
      fi
      mkdir "$run_lock_dir" 2>/dev/null || return 1
    fi
    : >"$run_lock_dir/owner-$$" 2>/dev/null || return 1
    owners=("$run_lock_dir"/owner-*)
    if [ "${#owners[@]}" -ne 1 ]; then
      rm -f "$run_lock_dir/owner-$$"
      return 1
    fi
  fi
}
release() {
  if have_flock; then flock -u 8; exec 8>&-; else rm -f "$run_lock_dir/owner-$$"; rmdir "$run_lock_dir" 2>/dev/null || true; fi
}
encode_batch() {
  if command -v jq >/dev/null 2>&1; then
    jq -sc --arg output "$configured_output" '{version:1,output:$output,events:(map(if type == "array" then . else [.] end) | add)} | @base64' "${batch[@]}" | tr -d '"\n'
  else
    ruby -rjson -rbase64 -e '
      output = ARGV.shift
      print Base64.strict_encode64(JSON.generate(version: 1, output: output,
        events: ARGV.flat_map { |path| value = JSON.parse(File.read(path)); value.is_a?(Array) ? value : [value] }))
    ' -- "$configured_output" "${batch[@]}"
  fi
}
run_batch() {
  encoded="$(encode_batch)" || return 1
  [ -n "$encoded" ] || return 1
  remaining=$((budget - SECONDS + started))
  [ "$remaining" -gt 0 ] || return 124
  rake="${WOODS_HOOK_RAKE:-bundle exec rake}"
  # Job control gives this command and its descendants a dedicated process group.
  # The task argument crosses Docker exec without requiring env forwarding or a
  # host-only queue path to exist inside the application container.
  set -m
  ( exec 8>&-; cd "$cwd" || exit 1; exec $rake "woods:hook_refresh[$encoded]" ) >>"$log" 2>&1 &
  runner=$!
  ( exec 8>&-; sleep "$remaining"; kill -TERM -- "-$runner" 2>/dev/null; sleep 1; kill -KILL -- "-$runner" 2>/dev/null ) >/dev/null 2>&1 &
  timer=$!
  wait "$runner" 2>/dev/null
  result=$?
  kill -KILL -- "-$runner" 2>/dev/null || true
  runner=""
  kill -TERM -- "-$timer" 2>/dev/null || true
  wait "$timer" 2>/dev/null || true
  timer=""
  set +m
  return "$result"
}
cleanup() {
  [ -z "${runner:-}" ] || kill -KILL -- "-$runner" 2>/dev/null || true
  [ -z "${timer:-}" ] || kill -TERM -- "-$timer" 2>/dev/null || true
  if [ "${legacy_directory_owned:-0}" = 1 ]; then
    rmdir "$tmp_dir/hook-pending.lock.d" 2>/dev/null || true
  fi
  release
}
shopt -s nullglob
acquire || exit 0
trap 'exit 143' TERM INT
trap 'cleanup' EXIT
# Upgrade recovery: import the previous newline queue before retiring it.
# A crash during import can duplicate an event but cannot erase its obligation.
legacy_pending="$tmp_dir/hook-pending.txt"
if [ -s "$legacy_pending" ]; then
  if have_flock; then
    exec 7>"$tmp_dir/hook-pending.lock"
    flock -n 7 || exit 0
  else
    if ! mkdir "$tmp_dir/hook-pending.lock.d" 2>/dev/null; then
      printf 'Legacy queue import deferred: hook-pending.lock.d is busy; both queues retained.\n' >>"$log"
      exit 0
    fi
    legacy_directory_owned=1
  fi
  while IFS= read -r legacy_path || [ -n "$legacy_path" ]; do
    [ "$((SECONDS - started))" -lt "$budget" ] || exit 0
    [ -n "$legacy_path" ] || continue
    enqueue "$legacy_path" || exit 0
  done <"$legacy_pending"
  rm -f "$legacy_pending"
  if have_flock; then
    flock -u 7
    exec 7>&-
  else
    rmdir "$tmp_dir/hook-pending.lock.d" 2>/dev/null || true
    legacy_directory_owned=0
  fi
fi
while :; do
  batch=("$queue"/*.json)
  if [ "${#batch[@]}" -eq 0 ]; then
    # Release before checking again: an arrival either becomes our next batch
    # or acquires ownership itself. There is no last-drain/release gap.
    release
    trap - EXIT
    batch=("$queue"/*.json)
    [ "${#batch[@]}" -gt 0 ] || break
    acquire || break
    trap 'cleanup' EXIT
    continue
  fi
  candidates=("${batch[@]:0:16}")
  batch=()
  batch_bytes=0
  batch_events=0
  for candidate in "${candidates[@]}"; do
    event_bytes="$(wc -c <"$candidate")"
    if command -v jq >/dev/null 2>&1; then
      event_count="$(jq 'if type == "array" then length else 1 end' "$candidate")" || break
    else
      event_count="$(ruby -rjson -e 'v = JSON.parse(File.read(ARGV[0])); puts(v.is_a?(Array) ? v.size : 1)' "$candidate")" || break
    fi
    [ "$((batch_events + event_count))" -le 1000 ] || break
    [ "$((batch_bytes + event_bytes))" -le 49152 ] || break
    batch+=("$candidate")
    batch_bytes=$((batch_bytes + event_bytes))
    batch_events=$((batch_events + event_count))
  done
  if [ "${#batch[@]}" -eq 0 ]; then
    printf 'Oversized hook event; pending work retained for inspection.\n' >>"$log"
    break
  fi
  if run_batch; then
    rm -f "${batch[@]}"
  else
    result=$?
    printf 'Woods hook deferred/failed (status %s); pending events retained in %s. Retry on the next edit or invoke the hook again after resolving the cause.\n' "$result" "$queue" >>"$log"
    break
  fi
done
exit 0
