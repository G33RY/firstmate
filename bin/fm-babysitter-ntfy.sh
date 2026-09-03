#!/usr/bin/env bash
# fm-babysitter-ntfy.sh - tier-2 escalation sender (docs/babysitter.md).
# Own small argv-safe curl dispatch, not bin/fm-supervise-daemon.sh's wedge
# alarm (sourcing that forces FM_WEDGE_ALARM_EXEC=discard for any sourced caller).
# Message is always one of three fixed templates with only plain integers
# interpolated - no caller text ever reaches the payload.
# Topic: $CONFIG/babysitter-ntfy-topic (mode 600/400); absent = tier 2 disabled.
# Rate limit: FM_BABYSITTER_NTFY_COOLDOWN_SECS (default 1800s), enforced here.
# Test seam: FM_BABYSITTER_NTFY_EXEC.
#
# Usage:
#   fm-babysitter-ntfy.sh notify --reason unmet-commitment|parked-checkpoint|judge-down \
#       --count <n> --oldest-seconds <s>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
TOPIC_FILE="$CONFIG/babysitter-ntfy-topic"
LAST_FILE="$STATE/.babysitter-ntfy-last"
COOLDOWN=${FM_BABYSITTER_NTFY_COOLDOWN_SECS:-1800}
TIMEOUT=${FM_BABYSITTER_NTFY_TIMEOUT_SECS:-10}
case "$COOLDOWN" in ''|*[!0-9]*) COOLDOWN=1800 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=10 ;; esac

usage() {
  echo "usage: fm-babysitter-ntfy.sh notify --reason unmet-commitment|parked-checkpoint|judge-down --count <n> --oldest-seconds <s>" >&2
  exit 2
}

bounded_uint() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 12 ]
}

read_topic() {
  [ -f "$TOPIC_FILE" ] && [ ! -L "$TOPIC_FILE" ] && [ -r "$TOPIC_FILE" ] || return 1
  local perm
  perm=$(LC_ALL=C stat -f '%Lp' "$TOPIC_FILE" 2>/dev/null || LC_ALL=C stat -c '%a' "$TOPIC_FILE" 2>/dev/null) || return 1
  case "$perm" in 600|400) ;; *) return 1 ;; esac
  local topic
  IFS= read -r topic < "$TOPIC_FILE" 2>/dev/null || return 1
  topic=${topic//[[:space:]]/}
  case "$topic" in '') return 1 ;; esac
  case "$topic" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  printf '%s' "$topic"
}

cooldown_elapsed() {
  local last now
  [ -e "$LAST_FILE" ] || return 0
  last=$(cat "$LAST_FILE" 2>/dev/null || echo 0)
  bounded_uint "$last" || return 0
  now=$(date +%s 2>/dev/null || echo 0)
  [ $((now - last)) -ge "$COOLDOWN" ]
}

record_sent() {
  local tmp
  tmp="$LAST_FILE.tmp.$$"
  date +%s > "$tmp" 2>/dev/null && mv -f "$tmp" "$LAST_FILE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  notify)
    REASON=''
    COUNT=''
    OLDEST=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --reason) REASON=${2:-}; shift 2 || usage ;;
        --count) COUNT=${2:-}; shift 2 || usage ;;
        --oldest-seconds) OLDEST=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    case "$REASON" in unmet-commitment|parked-checkpoint|judge-down) ;; *) usage ;; esac
    bounded_uint "$COUNT" || usage
    bounded_uint "$OLDEST" || usage

    TOPIC=$(read_topic) || exit 0
    cooldown_elapsed || exit 0

    case "$REASON" in
      unmet-commitment)
        MESSAGE=$(printf 'Firstmate: %s commitment(s) unmet, oldest %ss - check the terminal.' "$COUNT" "$OLDEST")
        ;;
      parked-checkpoint)
        MESSAGE=$(printf 'Firstmate: %s task(s) parked awaiting validation, oldest %ss - check the terminal.' "$COUNT" "$OLDEST")
        ;;
      judge-down)
        MESSAGE=$(printf 'Firstmate: the babysitter judge could not be revived after %s attempt(s), down %ss - check the terminal.' "$COUNT" "$OLDEST")
        ;;
    esac

    if [ -n "${FM_BABYSITTER_NTFY_EXEC:-}" ]; then
      printf '%s' "$MESSAGE" | "$FM_BABYSITTER_NTFY_EXEC" "$MESSAGE" >/dev/null 2>&1 || true
    else
      command -v curl >/dev/null 2>&1 || exit 0
      curl -sS -m "$TIMEOUT" -d "$MESSAGE" "https://ntfy.sh/$TOPIC" >/dev/null 2>&1 || true
    fi
    record_sent
    ;;
  *) usage ;;
esac
