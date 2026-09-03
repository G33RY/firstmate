#!/usr/bin/env bash
# fm-babysitter-findings.sh - judge's durable findings store (docs/babysitter.md).
# Same shape as bin/fm-branch-outcome.sh: append-only, gap-free JSONL plus a
# read cursor advanced only after acting, so a restart loses no finding and
# never re-acts on one already delivered.
# Store: $STATE/babysitter-findings.jsonl, {"seq","epoch","kind","summary","tier","ledger_through"}.
# Cursor: $STATE/.babysitter-findings-cursor.
#
# Usage:
#   fm-babysitter-findings.sh append --kind <kind> --summary <text> --tier <1|2> [--ledger-through <seq>]
#   fm-babysitter-findings.sh unread
#   fm-babysitter-findings.sh mark-read --through <seq>
#   fm-babysitter-findings.sh list [--recent <n>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

STORE="$STATE/babysitter-findings.jsonl"
CURSOR="$STATE/.babysitter-findings-cursor"
LOCK="$STATE/.babysitter-findings.lock"
MAX_SAFE_SEQ=9007199254740991

usage() {
  echo "usage: fm-babysitter-findings.sh append --kind <kind> --summary <text> --tier <1|2> [--ledger-through <seq>] | unread | mark-read --through <seq> | list [--recent <n>]" >&2
  exit 2
}

bounded_uint() {
  local value=$1
  case "$value" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#value}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$value" -le "$MAX_SAFE_SEQ" ]
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

read_cursor() {
  local value
  [ -e "$CURSOR" ] || { printf '0\n'; return 0; }
  if ! value=$(cat "$CURSOR" 2>/dev/null); then
    echo "error: refusing operation because the findings cursor is unreadable" >&2
    return 1
  fi
  bounded_uint "$value" || { echo "error: refusing operation because the findings cursor is malformed" >&2; return 1; }
  printf '%s\n' "$value"
}

last_seq() {
  [ -s "$STORE" ] || { printf '0\n'; return 0; }
  jq -Rse '
    def valid: type == "object"
      and (keys == ["epoch","kind","ledger_through","seq","summary","tier"])
      and ((.seq|type)=="number" and .seq>=1 and .seq<=9007199254740991 and .seq==(.seq|floor))
      and ((.epoch|type)=="number" and .epoch>=0 and .epoch==(.epoch|floor))
      and ((.tier==1) or (.tier==2))
      and ((.ledger_through|type)=="number" and .ledger_through>=0 and .ledger_through==(.ledger_through|floor))
      and ((.kind|type)=="string" and (.summary|type)=="string");
    if endswith("\n") then split("\n")[:-1] else error("unterminated findings store") end
    | map(fromjson)
    | . as $rows
    | if reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid and .seq == ($i + 1)))
      then .[-1].seq
      else error("malformed or non-sequential findings store")
      end
  ' "$STORE" 2>/dev/null
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    KIND=''
    SUMMARY=''
    TIER=''
    LEDGER_THROUGH=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --kind) KIND=${2:-}; shift 2 || usage ;;
        --summary) SUMMARY=${2:-}; shift 2 || usage ;;
        --tier) TIER=${2:-}; shift 2 || usage ;;
        --ledger-through) LEDGER_THROUGH=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$KIND" ] && [ -n "$SUMMARY" ] || usage
    case "$TIER" in 1|2) ;; *) usage ;; esac
    case "$LEDGER_THROUGH" in ''|*[!0-9]*) usage ;; esac
    fm_lock_acquire_wait "$LOCK"
    if ! LAST=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing append because the findings store is malformed or non-sequential" >&2
      exit 1
    fi
    SEQ=$((LAST + 1))
    printf '{"seq":%s,"epoch":%s,"kind":"%s","summary":"%s","tier":%s,"ledger_through":%s}\n' \
      "$SEQ" "$(date +%s)" "$(json_escape "$KIND")" "$(json_escape "$SUMMARY")" "$TIER" "$LEDGER_THROUGH" >> "$STORE"
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the findings store is malformed or non-sequential" >&2
      exit 1
    fi
    CURSOR_SEQ=$(read_cursor) || { fm_lock_release "$LOCK"; exit 1; }
    if [ -s "$STORE" ]; then
      jq -c --argjson cursor "$CURSOR_SEQ" 'select(.seq > $cursor)' "$STORE"
    fi
    fm_lock_release "$LOCK"
    ;;
  mark-read)
    [ "${1:-}" = --through ] || usage
    THROUGH=${2:-}
    bounded_uint "$THROUGH" || usage
    [ "$#" -eq 2 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! LAST=$(last_seq); then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement because the findings store is malformed or non-sequential" >&2
      exit 1
    fi
    CURSOR_SEQ=$(read_cursor) || { fm_lock_release "$LOCK"; exit 1; }
    if [ "$THROUGH" -gt "$LAST" ]; then
      fm_lock_release "$LOCK"
      echo "error: refusing cursor advancement beyond a valid stored finding" >&2
      exit 1
    fi
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      TMP=$(mktemp "$STATE/.babysitter-findings-cursor.XXXXXX")
      printf '%s\n' "$THROUGH" > "$TMP"
      mv -f -- "$TMP" "$CURSOR"
    fi
    fm_lock_release "$LOCK"
    ;;
  list)
    RECENT=20
    if [ "${1:-}" = --recent ]; then
      RECENT=${2:-}
      case "$RECENT" in ''|*[!0-9]*|0) usage ;; esac
      shift 2 || usage
    fi
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! last_seq >/dev/null; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the findings store is malformed or non-sequential" >&2
      exit 1
    fi
    [ -s "$STORE" ] && tail -n "$RECENT" "$STORE"
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
