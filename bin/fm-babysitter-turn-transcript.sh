#!/usr/bin/env bash
# fm-babysitter-turn-transcript.sh <record> - Claude worker Stop hook helper.
# Records the Stop payload's transcript_path for the context guard
# (bin/fm-babysitter-context-lib.sh). Never blocks a turn.
set -u

RECORD=${1:-}
[ -n "$RECORD" ] || exit 0
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r 'if (.transcript_path|type)=="string" then .transcript_path else empty end' 2>/dev/null) || exit 0
[ -n "$TRANSCRIPT" ] || exit 0
TMP="$RECORD.tmp.$$"
printf '%s\n' "$TRANSCRIPT" > "$TMP" 2>/dev/null && mv -f "$TMP" "$RECORD" 2>/dev/null || rm -f "$TMP" 2>/dev/null
exit 0
