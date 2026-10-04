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

TMP="$STATE/.babysitter-primary-busy.tmp.$$"
{
  printf 'state=%s\n' "$STATE_WORD"
  printf 'event=%s\n' "$EVENT"
  printf 'epoch=%s\n' "$(date +%s 2>/dev/null || echo 0)"
} > "$TMP" 2>/dev/null && mv -f "$TMP" "$STATE/.babysitter-primary-busy" 2>/dev/null || true
rm -f "$TMP" 2>/dev/null || true
exit 0
