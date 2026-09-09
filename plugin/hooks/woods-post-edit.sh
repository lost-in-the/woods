#!/usr/bin/env bash
# Woods PostToolUse hook (#280): after an edit to a graph-changing path,
# refresh the index with `woods:incremental` in the background.
#
# Reads `cwd` from the hook payload, not CLAUDE_PROJECT_DIR, so a session in
# a linked worktree refreshes that worktree's own index. Runs only when an
# index already exists there. `woods:incremental` stands down under a
# running watch daemon and takes the extraction lock itself; the lock here
# only stops this hook from queueing one rake process per keystroke.
#
# Opt-in: this hook is shipped disabled. It does nothing until
# WOODS_HOOKS_ENABLED=1 is set (see docs/WATCH_DAEMON.md and the woods-setup
# skill for where to set it). WOODS_HOOKS_DISABLED=1 turns it back off even
# after it has been enabled, without touching the enable setting.
#
# Lock contention must not drop an edit. A hook invocation that finds the
# run lock busy appends its path to hook-pending.txt and returns immediately
# instead of waiting; whichever invocation is holding the run lock drains
# that file in a loop, passing every path collected on each drain as one
# CHANGED_FILES batch, until a drain comes back empty. The one narrow gap
# this leaves: an append that lands after the holder's last (empty) drain
# but before it releases the run lock sits in the file, unprocessed, until
# the next graph-changing edit triggers a hook that both appends it and
# then wins the now-free run lock itself. That edit is delayed, not lost,
# and the SessionStart hook's staleness warning is the backstop for it.
#
# Knobs:
#   WOODS_HOOK_RAKE      command prefix, default "bundle exec rake"
#                        (Docker: "docker compose exec -T app bundle exec rake")
#   WOODS_OUTPUT         index directory override, same variable
#                        woods:incremental/woods:watch_status already read;
#                        default tmp/woods under the payload's cwd
#   WOODS_HOOKS_ENABLED  set to 1 to turn the hook on
#   WOODS_HOOKS_DISABLED set to 1 to turn it back off
set -u

[ "${WOODS_HOOKS_DISABLED:-0}" = "1" ] && exit 0
[ "${WOODS_HOOKS_ENABLED:-0}" = "1" ] || exit 0

payload="$(cat)"

# $1: dotted key path. Prefers jq, falls back to ruby, else gives up quietly.
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
file="$(field tool_input.file_path)"
[ -z "$cwd" ] && exit 0
[ -z "$file" ] && exit 0

# Same no-boot resolution woods:watch_status uses: an explicit WOODS_OUTPUT
# wins outright (absolute or relative to cwd), otherwise tmp/woods under cwd.
# This is the config's own override knob, not a second hardcoded path.
configured_output="${WOODS_OUTPUT:-tmp/woods}"
case "$configured_output" in
  /*) tmp_dir="$configured_output" ;;
  *) tmp_dir="$cwd/$configured_output" ;;
esac

[ -f "$tmp_dir/generation.json" ] || exit 0

case "$file" in
  "$cwd"/*) rel="${file#"$cwd"/}" ;;
  /*) exit 0 ;;
  *) rel="$file" ;;
esac

case "$rel" in
  app/models/*|config/routes.rb|config/routes/*|db/migrate/*|db/*_migrate/*|db/schema.rb|db/structure.sql|package.yml|*/package.yml|packwerk.yml) ;;
  *) exit 0 ;;
esac

rake="${WOODS_HOOK_RAKE:-bundle exec rake}"
log="$tmp_dir/hook.log"
pending_file="$tmp_dir/hook-pending.txt"
pending_lock="$tmp_dir/hook-pending.lock"
pending_lock_dir="$tmp_dir/hook-pending.lock.d"
run_lock="$tmp_dir/hook.lock"
run_lock_dir="$tmp_dir/hook.lock.d"

mkdir -p "$tmp_dir" 2>/dev/null || true

have_flock() { command -v flock >/dev/null 2>&1; }

# Append one path to the pending file. Blocking: the critical section is a
# single append, so any wait here is brief regardless of who else holds it.
append_pending() {
  if have_flock; then
    exec 7>"$pending_lock"
    flock 7
    printf '%s\n' "$1" >>"$pending_file"
    flock -u 7
    exec 7>&-
  else
    until mkdir "$pending_lock_dir" 2>/dev/null; do sleep 0.1; done
    printf '%s\n' "$1" >>"$pending_file"
    rmdir "$pending_lock_dir" 2>/dev/null || true
  fi
}

# Print and clear whatever is currently pending, empty output if nothing is.
drain_pending() {
  if have_flock; then
    exec 7>"$pending_lock"
    flock 7
    if [ -s "$pending_file" ]; then
      cat "$pending_file"
      : >"$pending_file"
    fi
    flock -u 7
    exec 7>&-
  else
    until mkdir "$pending_lock_dir" 2>/dev/null; do sleep 0.1; done
    if [ -s "$pending_file" ]; then
      cat "$pending_file"
      : >"$pending_file"
    fi
    rmdir "$pending_lock_dir" 2>/dev/null || true
  fi
}

run_incremental() {
  # A drain can return several paths at once; CHANGED_FILES takes a
  # comma-separated list (see lib/tasks/woods.rake).
  changed="$(printf '%s\n' "$1" | tr '\n' ',' | sed 's/,$//')"
  # shellcheck disable=SC2086
  ( cd "$cwd" && CHANGED_FILES="$changed" $rake woods:incremental ) >>"$log" 2>&1
}

drain_until_empty() {
  while :; do
    batch="$(drain_pending)"
    [ -z "$batch" ] && break
    run_incremental "$batch"
  done
}

append_pending "$rel"

if have_flock; then
  exec 8>"$run_lock"
  if flock -n 8; then
    drain_until_empty
    flock -u 8
  fi
  exec 8>&-
else
  if mkdir "$run_lock_dir" 2>/dev/null; then
    drain_until_empty
    rmdir "$run_lock_dir" 2>/dev/null || true
  fi
fi

exit 0
