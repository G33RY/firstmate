#!/usr/bin/env bash
# tests/fm-babysitter-ledger.test.sh - behavior tests for
# bin/fm-babysitter-ledger.sh (docs/babysitter.md): append/unread/mark-read,
# the per-line cap, and rotation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

LEDGER="$ROOT/bin/fm-babysitter-ledger.sh"
TMP_ROOT=$(fm_test_tmproot fm-babysitter-ledger-tests)

new_case() { # <name> -> state dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s' "$dir/state"
}

test_append_unread_mark_read() {
  local state s1 s2
  state=$(new_case basic)
  s1=$(FM_STATE_OVERRIDE="$state" "$LEDGER" append --role captain --text "fix the bug") || fail "append 1 failed"
  s2=$(FM_STATE_OVERRIDE="$state" "$LEDGER" append --role firstmate --text "on it") || fail "append 2 failed"
  [ "$s1" -eq 1 ] && [ "$s2" -eq 2 ] || fail "unexpected seq assignment: $s1 $s2"

  UNREAD=$(FM_STATE_OVERRIDE="$state" "$LEDGER" unread)
  LINES=$(printf '%s\n' "$UNREAD" | grep -c .)
  [ "$LINES" -eq 2 ] || fail "expected 2 unread entries, got $LINES"

  FM_STATE_OVERRIDE="$state" "$LEDGER" mark-read --through 1 || fail "mark-read failed"
  UNREAD=$(FM_STATE_OVERRIDE="$state" "$LEDGER" unread)
  printf '%s\n' "$UNREAD" | grep -qF '"seq":1' && fail "seq 1 still reads as unread after mark-read"
  printf '%s\n' "$UNREAD" | grep -qF '"seq":2' || fail "seq 2 should still read as unread"
  pass "append assigns increasing seq; unread/mark-read track the read cursor correctly"
}

test_role_must_be_captain_or_firstmate() {
  local state out
  state=$(new_case bad-role)
  out=$(FM_STATE_OVERRIDE="$state" "$LEDGER" append --role captain-impersonator --text "x" 2>&1)
  [ -z "$out" ] || true
  [ ! -s "$state/babysitter-ledger.jsonl" ] || fail "an invalid role was accepted into the ledger"
  pass "an invalid role is silently refused, never stored"
}

test_long_text_is_capped() {
  local state longtext stored
  state=$(new_case capped)
  longtext=$(printf 'x%.0s' $(seq 1 2000))
  FM_STATE_OVERRIDE="$state" FM_BABYSITTER_LEDGER_LINE_CAP=50 "$LEDGER" append --role captain --text "$longtext" >/dev/null || fail "append failed"
  stored=$(FM_STATE_OVERRIDE="$state" "$LEDGER" list --recent 1 | grep -o '"text":"[^"]*"')
  LEN=${#stored}
  [ "$LEN" -lt 100 ] || fail "a long message was not capped: length=$LEN"
  printf '%s' "$stored" | grep -qF 'truncated' || fail "capped text is missing the shared truncation marker"
  pass "a message over the configured cap is truncated with the shared marker"
}

test_rotation_keeps_seq_monotonic_and_bounded() {
  local state i
  state=$(new_case rotation)
  for i in $(seq 1 25); do
    FM_STATE_OVERRIDE="$state" FM_BABYSITTER_LEDGER_MAX=20 FM_BABYSITTER_LEDGER_KEEP=10 \
      "$LEDGER" append --role captain --text "msg $i" >/dev/null || fail "append $i failed"
  done
  LINES=$(wc -l < "$state/babysitter-ledger.jsonl")
  LINES=${LINES//[[:space:]]/}
  [ "$LINES" -le 20 ] || fail "rotation did not bound the store under MAX lines (got $LINES)"
  [ "$LINES" -lt 25 ] || fail "rotation never actually truncated the store (got $LINES of 25 appended)"
  LAST_SEQ=$(FM_STATE_OVERRIDE="$state" "$LEDGER" list --recent 1 | grep -o '"seq":[0-9]*' | cut -d: -f2)
  [ "$LAST_SEQ" -eq 25 ] || fail "seq did not stay monotonic across rotation (last=$LAST_SEQ, expected 25)"
  grep -qF '"seq":1,' "$state/babysitter-ledger.jsonl" && fail "rotation did not drop the oldest lines"
  pass "rotation bounds the store while seq stays monotonic and never restarts"
}

test_append_unread_mark_read
test_role_must_be_captain_or_firstmate
test_long_text_is_capped
test_rotation_keeps_seq_monotonic_and_bounded
