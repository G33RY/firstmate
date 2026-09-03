#!/usr/bin/env bash
# fm-babysitter-liveness-lib.sh - deterministic judge liveness (docs/babysitter.md).
# Called from bin/fm-bootstrap.sh (session start) and state/babysitter.check.sh
# (mid-session watcher poll). Prints one BABYSITTER_LIVENESS: line only when
# actionable, nothing when alive - that stdout doubles as the check.sh wake.
set -u

FM_BABYSITTER_LIVENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_babysitter_liveness_check() {
  # shellcheck disable=SC2153 # $STATE/$CONFIG are resolved by the caller before sourcing this lib.
  local meta="$STATE/babysitter.meta" backend target agent_state
  local enabled_flag="$CONFIG/babysitter-enabled"
  local attempts_file="$STATE/.babysitter-relaunch-attempts"
  local down_since_file="$STATE/.babysitter-down-since"
  local max_attempts=${FM_BABYSITTER_LIVENESS_MAX_ATTEMPTS:-3}
  local attempts down_since age

  case "$max_attempts" in ''|*[!0-9]*) max_attempts=3 ;; esac

  # Opt-in only: config/babysitter-enabled must exist before this ever spawns
  # or relaunches anything. Without it, every home and every test sandbox
  # that merely runs session start stays a true no-op - no tmux, no process.
  [ -e "$enabled_flag" ] || return 0

  if [ ! -f "$meta" ]; then
    if "$FM_BABYSITTER_LIVENESS_LIB_DIR/fm-babysitter-spawn.sh" launch >/dev/null 2>&1; then
      return 0
    fi
    printf 'BABYSITTER_LIVENESS: initial spawn failed\n'
    return 0
  fi

  if ! command -v fm_backend_agent_state >/dev/null 2>&1; then
    # shellcheck source=bin/fm-backend.sh
    . "$FM_BABYSITTER_LIVENESS_LIB_DIR/fm-backend.sh"
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable

  case "$agent_state" in
    alive)
      rm -f "$attempts_file" "$down_since_file" 2>/dev/null || true
      return 0
      ;;
    dead|missing)
      [ -e "$down_since_file" ] || date +%s > "$down_since_file" 2>/dev/null || true
      attempts=$(cat "$attempts_file" 2>/dev/null || echo 0)
      case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
      attempts=$((attempts + 1))
      printf '%s\n' "$attempts" > "$attempts_file" 2>/dev/null || true

      if [ "$attempts" -gt "$max_attempts" ]; then
        down_since=$(cat "$down_since_file" 2>/dev/null || date +%s)
        case "$down_since" in ''|*[!0-9]*) down_since=$(date +%s) ;; esac
        age=$(( $(date +%s) - down_since ))
        [ "$age" -ge 0 ] || age=0
        if [ -x "$FM_BABYSITTER_LIVENESS_LIB_DIR/fm-babysitter-ntfy.sh" ]; then
          "$FM_BABYSITTER_LIVENESS_LIB_DIR/fm-babysitter-ntfy.sh" notify \
            --reason judge-down --count "$attempts" --oldest-seconds "$age" >/dev/null 2>&1 || true
        fi
        printf 'BABYSITTER_LIVENESS: could not be revived after %s attempt(s), down %ss - the captain has been notified\n' "$attempts" "$age"
        return 0
      fi

      if "$FM_BABYSITTER_LIVENESS_LIB_DIR/fm-babysitter-spawn.sh" launch >/dev/null 2>&1; then
        printf 'BABYSITTER_LIVENESS: was %s, relaunched (attempt %s of %s)\n' "$agent_state" "$attempts" "$max_attempts"
      else
        printf 'BABYSITTER_LIVENESS: was %s, relaunch failed (attempt %s of %s)\n' "$agent_state" "$attempts" "$max_attempts"
      fi
      ;;
    *)
      printf 'BABYSITTER_LIVENESS: skipped: agent recovery classifier reports %s (backend=%s)\n' "$agent_state" "$backend"
      ;;
  esac
}
