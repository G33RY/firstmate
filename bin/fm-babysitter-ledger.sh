#!/usr/bin/env bash
# fm-babysitter-ledger.sh - durable captain/firstmate dialog ledger (docs/babysitter.md).
# Store: $STATE/babysitter-ledger.jsonl, one {"seq","epoch","role","text"} per line.
# seq is a persistent monotonic counter, so it survives rotation (tail+mv past
# FM_BABYSITTER_LEDGER_MAX lines, kept to FM_BABYSITTER_LEDGER_KEEP).
# Cursor: $STATE/.babysitter-ledger-cursor, the judge's read position.
#
# Usage:
#   fm-babysitter-ledger.sh append --role captain|firstmate --text <text>
#   fm-babysitter-ledger.sh unread
#   fm-babysitter-ledger.sh mark-read --through <seq>
#   fm-babysitter-ledger.sh list [--recent <n>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

STORE="$STATE/babysitter-ledger.jsonl"
CURSOR="$STATE/.babysitter-ledger-cursor"
SEQFILE="$STATE/.babysitter-ledger-seq"
LOCK="$STATE/.babysitter-ledger.lock"
MAX_LINES=${FM_BABYSITTER_LEDGER_MAX:-4000}
KEEP_LINES=${FM_BABYSITTER_LEDGER_KEEP:-3000}
LINE_CAP=${FM_BABYSITTER_LEDGER_LINE_CAP:-800}
MAX_SAFE_SEQ=9007199254740991

usage() {
  echo "usage: fm-babysitter-ledger.sh append --role captain|firstmate --text <text> | unread | mark-read --through <seq> | list [--recent <n>]" >&2
  exit 2
}

bounded_uint() {
  case "${1:-}" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "${#1}" -le "${#MAX_SAFE_SEQ}" ] || return 1
  [ "$1" -le "$MAX_SAFE_SEQ" ]
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
  value=$(cat "$CURSOR" 2>/dev/null) || { printf '0\n'; return 0; }
  bounded_uint "$value" || { printf '0\n'; return 0; }
  printf '%s\n' "$value"
}

next_seq() {
  local seq
  seq=$(cat "$SEQFILE" 2>/dev/null || echo 0)
  case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$SEQFILE" || return 1
  printf '%s\n' "$seq"
}

store_valid() { # exits 0 iff every line parses with the exact schema and seq strictly increases
  [ -s "$STORE" ] || return 0
  jq -Rse '
    def valid: type == "object" and keys == ["epoch","role","seq","text"]
      and ((.seq|type)=="number" and .seq>=1 and .seq<=9007199254740991 and .seq==(.seq|floor))
      and ((.epoch|type)=="number" and .epoch>=0 and .epoch==(.epoch|floor))
      and ((.role=="captain") or (.role=="firstmate"))
      and ((.text|type)=="string");
    if endswith("\n") then split("\n")[:-1] else error("unterminated ledger") end
    | map(fromjson)
    | . as $rows
    | reduce range(0; length) as $i
        (true; . and ($rows[$i] | valid) and (if $i>0 then $rows[$i].seq > $rows[$i-1].seq else true end))
  ' "$STORE" >/dev/null 2>&1
}

rotate_if_needed() {
  local lines tmp
  lines=$(wc -l < "$STORE" 2>/dev/null || echo 0)
  lines=${lines//[[:space:]]/}
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  [ "$lines" -gt "$MAX_LINES" ] || return 0
  tmp="$STORE.tmp.$$"
  tail -n "$KEEP_LINES" "$STORE" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$STORE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  append)
    ROLE=''
    TEXT=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --role) ROLE=${2:-}; shift 2 || usage ;;
        --text) TEXT=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    case "$ROLE" in captain|firstmate) ;; *) exit 0 ;; esac
    [ -n "$TEXT" ] || exit 0
    fm_cap_line_var "$TEXT" "$LINE_CAP"
    TEXT=$FM_LINE_CAP_LINE
    fm_lock_try_acquire "$LOCK" || exit 0
    SEQ=$(next_seq) || { fm_lock_release "$LOCK"; exit 0; }
    printf '{"seq":%s,"epoch":%s,"role":"%s","text":"%s"}\n' \
      "$SEQ" "$(date +%s)" "$ROLE" "$(json_escape "$TEXT")" >> "$STORE" 2>/dev/null || {
        fm_lock_release "$LOCK"; exit 0
      }
    rotate_if_needed || true
    fm_lock_release "$LOCK"
    printf '%s\n' "$SEQ"
    ;;
  unread)
    [ "$#" -eq 0 ] || usage
    fm_lock_acquire_wait "$LOCK"
    if ! store_valid; then
      fm_lock_release "$LOCK"
      echo "error: refusing read because the ledger is malformed or out of order" >&2
      exit 1
    fi
    CURSOR_SEQ=$(read_cursor)
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
    CURSOR_SEQ=$(read_cursor)
    if [ "$THROUGH" -gt "$CURSOR_SEQ" ]; then
      TMP=$(mktemp "$STATE/.babysitter-ledger-cursor.XXXXXX") || { fm_lock_release "$LOCK"; exit 1; }
      if ! printf '%s\n' "$THROUGH" > "$TMP" || ! mv -f -- "$TMP" "$CURSOR"; then
        rm -f "$TMP"; fm_lock_release "$LOCK"; exit 1
      fi
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
    [ -s "$STORE" ] && tail -n "$RECENT" "$STORE"
    fm_lock_release "$LOCK"
    ;;
  *) usage ;;
esac
