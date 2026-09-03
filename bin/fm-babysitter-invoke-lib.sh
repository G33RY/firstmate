#!/usr/bin/env bash
# fm-babysitter-invoke-lib.sh - deterministic judge pass cadence (docs/babysitter.md).
# The judge's own brief says "you will be re-invoked" but nothing ever did; this
# is that trigger, bash-level and never the judge's own responsibility, same
# reasoning as fm-babysitter-liveness-lib.sh for liveness. Called from
# state/babysitter.check.sh on the watcher's poll cadence (bin/fm-watch.sh);
# not a second scheduler.
#
# Trigger: unread ledger content (bin/fm-babysitter-ledger.sh unread), or a
# minimum interval so a long quiet stretch still gets one stall sweep even
# with no new dialog. Never overlaps a dispatched-but-not-yet-acknowledged
# pass: fm-task-inbox-lib.sh's own contract is that the worker's mv into
# handled/ IS the acknowledgement, so one unhandled invoke record in the
# judge's steering inbox is read as "a pass is already in flight" and skips
# this poll. An unhandled record older than FM_BABYSITTER_INVOKE_STUCK_SECS is
# instead treated as orphaned (e.g. the judge died mid-pass and was relaunched
# by the liveness layer without ever reading it) and retired into handled/ so
# the busy gate does not wedge open forever.
#
# Delivery is an ordinary steer through bin/fm-send.sh's durable inbox, never
# typed at the pane directly.
set -u

FM_BABYSITTER_INVOKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Portable mtime in epoch seconds; see bin/fm-busy-event.sh for why the two
# stat forms are never collapsed into one fallback expression.
if [ "$(uname)" = Darwin ]; then
  fm_babysitter_invoke_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  fm_babysitter_invoke_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

# Oldest unhandled invoke record in <inbox-dir>, or empty when none.
fm_babysitter_invoke_oldest_msg() {  # <inbox-dir>
  local dir=$1 f n oldest='' oldest_n=0
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    n=${f##*/}
    n=${n%.msg}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$oldest" ] || [ "$((10#$n))" -lt "$oldest_n" ]; then
      oldest=$f
      oldest_n=$((10#$n))
    fi
  done
  printf '%s' "$oldest"
}

fm_babysitter_invoke_check() {
  # shellcheck disable=SC2153 # $STATE/$CONFIG are resolved by the caller before sourcing this lib.
  local meta="$STATE/babysitter.meta" enabled_flag="$CONFIG/babysitter-enabled"
  local inbox="$STATE/babysitter.inbox"
  local last_invoke_file="$STATE/.babysitter-last-invoke"
  local sweep_secs=${FM_BABYSITTER_SWEEP_INTERVAL_SECS:-1800}
  local stuck_secs=${FM_BABYSITTER_INVOKE_STUCK_SECS:-600}
  local backend target agent_state oldest now age unread last_invoke home

  case "$sweep_secs" in ''|*[!0-9]*) sweep_secs=1800 ;; esac
  case "$stuck_secs" in ''|*[!0-9]*) stuck_secs=600 ;; esac

  # Opt-in only, exactly like the liveness layer: without config/babysitter-enabled
  # this stays a true no-op - no ledger read, no inbox write, nothing probed.
  [ -e "$enabled_flag" ] || return 0
  [ -f "$meta" ] || return 0

  if ! command -v fm_backend_agent_state >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backend.sh
    . "$FM_BABYSITTER_INVOKE_LIB_DIR/fm-backend.sh"
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  [ "$agent_state" = alive ] || return 0

  now=$(date +%s)

  oldest=$(fm_babysitter_invoke_oldest_msg "$inbox")
  if [ -n "$oldest" ]; then
    age=$(( now - $(fm_babysitter_invoke_mtime "$oldest" || echo "$now") ))
    case "$age" in ''|*[!0-9]*) age=0 ;; esac
    if [ "$age" -lt "$stuck_secs" ]; then
      return 0
    fi
    mkdir -p "$inbox/handled" 2>/dev/null || true
    mv -f "$oldest" "$inbox/handled/${oldest##*/}" 2>/dev/null || true
  fi

  unread=$(FM_STATE_OVERRIDE="$STATE" "$FM_BABYSITTER_INVOKE_LIB_DIR/fm-babysitter-ledger.sh" unread 2>/dev/null) || unread=""
  if [ -z "$unread" ]; then
    # No prior dispatch recorded yet: start the sweep clock now rather than
    # treating "never" as infinitely overdue, so a judge that just spawned
    # (already running its own first pass) is not immediately re-invoked too.
    if [ ! -f "$last_invoke_file" ]; then
      printf '%s\n' "$now" > "$last_invoke_file" 2>/dev/null || true
      return 0
    fi
    last_invoke=$(cat "$last_invoke_file" 2>/dev/null || echo "$now")
    case "$last_invoke" in ''|*[!0-9]*) last_invoke=$now ;; esac
    [ "$(( now - last_invoke ))" -ge "$sweep_secs" ] || return 0
  fi

  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-}}"
  [ -n "$home" ] || return 0

  if FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" \
      "$FM_BABYSITTER_INVOKE_LIB_DIR/fm-send.sh" babysitter \
      "Run one judge pass now: docs/babysitter.md's \"Judge pass\" procedure." \
      >/dev/null 2>&1; then
    printf '%s\n' "$now" > "$last_invoke_file" 2>/dev/null || true
  fi
}
