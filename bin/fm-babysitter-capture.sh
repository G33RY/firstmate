#!/usr/bin/env bash
# Babysitter dialog-capture turn-end hook (docs/babysitter.md).
# Third tracked Claude Stop hook (.claude/settings.json); never blocks a turn.
# Ledger format (rotation, cap, cursor) is owned by bin/fm-babysitter-ledger.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

MARKER="$STATE/.babysitter-capture-error"
note_error() { # <reason>
  { printf '%s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" > "$MARKER.tmp.$$" \
      && mv -f "$MARKER.tmp.$$" "$MARKER"; } 2>/dev/null || true
  rm -f "$MARKER.tmp.$$" 2>/dev/null || true
}

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r 'if (.session_id|type)=="string" then .session_id else empty end' 2>/dev/null) || exit 0
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r 'if (.transcript_path|type)=="string" then .transcript_path else empty end' 2>/dev/null) || exit 0
[ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] || { note_error "malformed payload: missing session_id or transcript_path"; exit 0; }
[ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ] && [ ! -L "$TRANSCRIPT" ] || { note_error "transcript unavailable: $TRANSCRIPT"; exit 0; }

CURSOR_FILE="$STATE/.babysitter-transcript-cursor"
LOCK="$STATE/.babysitter-capture.lock"
fm_lock_try_acquire "$LOCK" || exit 0
DELTA_FILE=''
COMPLETE_FILE=''
# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup() {
  [ -z "$DELTA_FILE" ] || rm -f "$DELTA_FILE" 2>/dev/null || true
  [ -z "$COMPLETE_FILE" ] || [ "$COMPLETE_FILE" = "$DELTA_FILE" ] || rm -f "$COMPLETE_FILE" 2>/dev/null || true
  fm_lock_release "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT

CUR_SESSION=''
CUR_OFFSET=0
if [ -f "$CURSOR_FILE" ] && [ ! -L "$CURSOR_FILE" ] && [ -r "$CURSOR_FILE" ]; then
  IFS=$'\t' read -r CUR_SESSION CUR_OFFSET < "$CURSOR_FILE" 2>/dev/null || { CUR_SESSION=''; CUR_OFFSET=0; }
fi
case "$CUR_OFFSET" in ''|*[!0-9]*) CUR_OFFSET=0 ;; esac
[ "$CUR_SESSION" = "$SESSION_ID" ] || CUR_OFFSET=0

FILE_SIZE=$(wc -c < "$TRANSCRIPT" 2>/dev/null || echo '')
FILE_SIZE=${FILE_SIZE//[[:space:]]/}
case "$FILE_SIZE" in ''|*[!0-9]*) note_error "transcript size unreadable: $TRANSCRIPT"; exit 0 ;; esac
[ "$CUR_OFFSET" -le "$FILE_SIZE" ] || CUR_OFFSET=0

TMPDIR_SAFE=${TMPDIR:-/tmp}
DELTA_FILE=$(mktemp "$TMPDIR_SAFE/fm-babysitter-delta.XXXXXX" 2>/dev/null) || { note_error "mktemp failed (disk full?)"; exit 0; }

if [ "$CUR_OFFSET" -lt "$FILE_SIZE" ]; then
  tail -c "+$((CUR_OFFSET + 1))" "$TRANSCRIPT" > "$DELTA_FILE" 2>/dev/null || { note_error "delta read failed"; exit 0; }
fi

ADVANCE=0
if [ -s "$DELTA_FILE" ]; then
  LAST_BYTE=$(tail -c 1 "$DELTA_FILE" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
  if [ "$LAST_BYTE" = 0a ]; then
    COMPLETE_FILE=$DELTA_FILE
  else
    LINES=$(wc -l < "$DELTA_FILE" 2>/dev/null || echo 0)
    LINES=${LINES//[[:space:]]/}
    case "$LINES" in ''|*[!0-9]*) LINES=0 ;; esac
    if [ "$LINES" -gt 0 ]; then
      COMPLETE_FILE=$(mktemp "$TMPDIR_SAFE/fm-babysitter-complete.XXXXXX" 2>/dev/null) || { note_error "mktemp failed (disk full?)"; exit 0; }
      head -n "$LINES" "$DELTA_FILE" > "$COMPLETE_FILE" 2>/dev/null || { note_error "partial-line split failed"; exit 0; }
    else
      COMPLETE_FILE=''
    fi
  fi
  if [ -n "$COMPLETE_FILE" ] && [ -s "$COMPLETE_FILE" ]; then
    COMPLETE_SIZE=$(wc -c < "$COMPLETE_FILE" 2>/dev/null || echo 0)
    COMPLETE_SIZE=${COMPLETE_SIZE//[[:space:]]/}
    case "$COMPLETE_SIZE" in ''|*[!0-9]*) COMPLETE_SIZE=0 ;; esac
    ADVANCE=$COMPLETE_SIZE

    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      result=$(printf '%s' "$line" | jq -c '
        select((.type=="user" or .type=="assistant") and (.isSidechain != true))
        | .message as $m
        | ($m.role // .type) as $role
        | (
            if ($m.content|type)=="string" then $m.content
            elif ($m.content|type)=="array" then
              ([$m.content[]? | select((.type // "")=="text") | (.text // "")] | join("\n"))
            else null
            end
          ) as $text
        | select($text != null and (($text|gsub("\\s";""))|length) > 0)
        | {role: $role, text: $text}
      ' 2>/dev/null)
      [ -n "$result" ] || continue
      role=$(printf '%s' "$result" | jq -r '.role // empty' 2>/dev/null)
      text=$(printf '%s' "$result" | jq -r '.text // empty' 2>/dev/null)
      [ -n "$text" ] || continue
      case "$role" in
        user) LEDGER_ROLE=captain ;;
        assistant) LEDGER_ROLE=firstmate ;;
        *) continue ;;
      esac
      if [ "$LEDGER_ROLE" = captain ]; then
        # shellcheck disable=SC2034 # Required out-param; only the match/no-match matters here.
        CLASSIFY_KIND=''
        fm_operational_input_classify "$text" CLASSIFY_KIND && continue
        case "$text" in
          '<local-command-caveat>'*|'<command-name>'*|'<command-message>'*| \
          '<bash-input>'*|'<bash-stdout>'*|'<bash-stderr>'*|'<local-command-stdout>'*| \
          '<system-reminder>'*|'[Request interrupted'*)
            continue
            ;;
        esac
      fi
      "$SCRIPT_DIR/fm-babysitter-ledger.sh" append --role "$LEDGER_ROLE" --text "$text" >/dev/null 2>&1 || true
    done < "$COMPLETE_FILE"
  fi
fi

if [ "$ADVANCE" -gt 0 ]; then
  NEW_OFFSET=$((CUR_OFFSET + ADVANCE))
  CURSOR_TMP=$(mktemp "$TMPDIR_SAFE/fm-babysitter-cursor.XXXXXX" 2>/dev/null) || { note_error "mktemp failed (disk full?)"; exit 0; }
  if ! printf '%s\t%s\n' "$SESSION_ID" "$NEW_OFFSET" > "$CURSOR_TMP" 2>/dev/null \
    || ! mv -f "$CURSOR_TMP" "$CURSOR_FILE" 2>/dev/null; then
    note_error "cursor write failed"
  fi
  rm -f "$CURSOR_TMP" 2>/dev/null || true
fi

exit 0
