#!/usr/bin/env bash
# fm-babysitter-primary-state.sh - record primary turn lifecycle breadcrumbs.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"

STATE_WORD=${1:-}
EVENT=${2:-unknown}
case "$STATE_WORD" in busy|idle) ;; *) exit 0 ;; esac

PAYLOAD=$(cat 2>/dev/null || true)
if [ -n "$PAYLOAD" ] && fm_hook_payload_is_foreign_host "$PAYLOAD"; then
  exit 0
fi
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

SESSION_ID=
TRANSCRIPT=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r 'if (.session_id|type)=="string" then .session_id else empty end' 2>/dev/null) || SESSION_ID=
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r 'if (.transcript_path|type)=="string" then .transcript_path else empty end' 2>/dev/null) || TRANSCRIPT=
fi

TMP="$STATE/.babysitter-primary-busy.tmp.$$"
{
  printf 'state=%s\n' "$STATE_WORD"
  printf 'event=%s\n' "$EVENT"
  printf 'epoch=%s\n' "$(date +%s 2>/dev/null || echo 0)"
  [ -z "$SESSION_ID" ] || printf 'session_id=%s\n' "$SESSION_ID"
  [ -z "$TRANSCRIPT" ] || printf 'transcript=%s\n' "$TRANSCRIPT"
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE/.babysitter-primary-busy" 2>/dev/null || true
rm -f "$TMP" 2>/dev/null || true
exit 0
