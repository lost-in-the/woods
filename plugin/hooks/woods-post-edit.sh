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
# The mkdir-based lock fallback has no kernel-enforced release: a `flock`
# held by a killed process is freed automatically, but a lock *directory*
# a killed process made is not. A hook killed mid-drain (OOM, a `kill -9`,
# the host restarting) leaves `hook.lock.d` or `hook-pending.lock.d` behind
# forever, so every later hook either skips draining permanently (the run
# lock) or spins until the 600s hook timeout on every single invocation
# (the pending lock, which blocks). Both lock directories are therefore
# reclaimed once their mtime is older than WOODS_HOOK_LOCK_STALE_SECONDS: a
# fresh lock directory is still respected as busy.
#
# Knobs:
#   WOODS_HOOK_RAKE      command prefix, default "bundle exec rake"
#                        (Docker: "docker compose exec -T app bundle exec rake")
#   WOODS_OUTPUT         index directory override, same variable
#                        woods:incremental/woods:watch_status already read;
#                        default tmp/woods under the payload's cwd
#   WOODS_HOOKS_ENABLED  set to 1 to turn the hook on
#   WOODS_HOOKS_DISABLED set to 1 to turn it back off
#   WOODS_HOOK_LOCK_STALE_SECONDS
#                        age (mtime) after which a leftover mkdir-based lock
#                        directory is reclaimed instead of respected as busy;
#                        default 1800 (a few multiples of the 600s hook
#                        timeout). Only the mkdir fallback needs this;
#                        flock has no equivalent problem.
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

# mtime of a directory in epoch seconds, GNU stat then BSD stat, empty if
# neither exists (treated as "not stale": fail closed, keep waiting rather
# than reclaim on a guess).
dir_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# True when $1 is an mkdir-based lock directory old enough that it can only
# be a crash leftover, never a legitimately still-running hook (a hook run
# is one rake invocation, bounded by the 600s hook timeout).
lock_dir_stale() {
  mtime="$(dir_mtime "$1")"
  [ -z "$mtime" ] && return 1
  now="$(date +%s)"
  age=$((now - mtime))
  [ "$age" -gt "${WOODS_HOOK_LOCK_STALE_SECONDS:-1800}" ]
}

# Blocking mkdir-based lock acquire: waits for $1, reclaiming it once stale
# rather than waiting for a crashed holder that will never release it.
acquire_mkdir_lock() {
  while ! mkdir "$1" 2>/dev/null; do
    if lock_dir_stale "$1"; then
      rmdir "$1" 2>/dev/null || true
      continue
    fi
    sleep 0.1
  done
}

release_mkdir_lock() {
  rmdir "$1" 2>/dev/null || true
}

# Non-blocking mkdir-based lock attempt: one reclaim retry when stale, no
# wait otherwise (contention here means "someone else is already draining,"
# not "someone crashed").
try_acquire_mkdir_lock() {
  mkdir "$1" 2>/dev/null && return 0
  if lock_dir_stale "$1"; then
    rmdir "$1" 2>/dev/null || true
    mkdir "$1" 2>/dev/null && return 0
  fi
  return 1
}

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
    acquire_mkdir_lock "$pending_lock_dir"
    printf '%s\n' "$1" >>"$pending_file"
    release_mkdir_lock "$pending_lock_dir"
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
    acquire_mkdir_lock "$pending_lock_dir"
    if [ -s "$pending_file" ]; then
      cat "$pending_file"
      : >"$pending_file"
    fi
    release_mkdir_lock "$pending_lock_dir"
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
  if try_acquire_mkdir_lock "$run_lock_dir"; then
    drain_until_empty
    release_mkdir_lock "$run_lock_dir"
  fi
fi

exit 0
