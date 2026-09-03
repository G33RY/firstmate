#!/usr/bin/env bash
# tests/fm-babysitter-findings.test.sh - behavior tests for
# bin/fm-babysitter-findings.sh (docs/babysitter.md): the judge's durable
# findings store, mirroring bin/fm-branch-outcome.sh's shape - restart-safe
# append-only log plus a read cursor.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

FINDINGS="$ROOT/bin/fm-babysitter-findings.sh"
TMP_ROOT=$(fm_test_tmproot fm-babysitter-findings-tests)

new_case() { # <name> -> state dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state"
  printf '%s' "$dir/state"
}

test_append_unread_mark_read() {
  local state s1 s2
  state=$(new_case basic)
  s1=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind unmet-commitment --summary "said would fix X" --tier 1 --ledger-through 3) || fail "append 1 failed"
  s2=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind stall --summary "no progress" --tier 2 --ledger-through 9) || fail "append 2 failed"
  [ "$s1" -eq 1 ] && [ "$s2" -eq 2 ] || fail "unexpected seq assignment: $s1 $s2"

  UNREAD=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" unread)
  LINES=$(printf '%s\n' "$UNREAD" | grep -c .)
  [ "$LINES" -eq 2 ] || fail "expected 2 unread findings, got $LINES"

  FM_STATE_OVERRIDE="$state" "$FINDINGS" mark-read --through 1 || fail "mark-read failed"
  UNREAD=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" unread)
  printf '%s\n' "$UNREAD" | grep -qF '"seq":1,' && fail "seq 1 still reads as unread after mark-read"
  printf '%s\n' "$UNREAD" | grep -qF '"seq":2,' || fail "seq 2 should still read as unread"
  pass "append assigns increasing seq; unread/mark-read track the acted-on cursor correctly"
}

test_restart_survives_kill_between_write_and_ack() {
  local state
  state=$(new_case restart)
  FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind unmet-commitment --summary "finding A" --tier 1 --ledger-through 5 >/dev/null || fail "append failed"
  # Simulate a kill: the finding is durably stored but never acknowledged.
  UNREAD=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" unread)
  printf '%s\n' "$UNREAD" | grep -qF 'finding A' || fail "an unacknowledged finding was lost across a simulated restart"
  # A fresh process picking this up sees the exact same unread finding, never a duplicate.
  UNREAD2=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" unread)
  [ "$UNREAD" = "$UNREAD2" ] || fail "unread findings were not stable across repeated reads"
  pass "a finding written but never acknowledged survives a simulated restart and is read exactly once as unread"
}

test_tier_must_be_1_or_2() {
  local state rc
  state=$(new_case bad-tier)
  rc=0
  FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind stall --summary "x" --tier 3 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an invalid tier was accepted"
  [ ! -s "$state/babysitter-findings.jsonl" ] || fail "an invalid-tier finding was stored"
  pass "an invalid tier is refused, never stored"
}

test_list_shows_recent_regardless_of_read_state() {
  local state
  state=$(new_case list)
  FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind stall --summary "a" --tier 1 --ledger-through 1 >/dev/null
  FM_STATE_OVERRIDE="$state" "$FINDINGS" append --kind stall --summary "b" --tier 1 --ledger-through 2 >/dev/null
  FM_STATE_OVERRIDE="$state" "$FINDINGS" mark-read --through 2
  LISTED=$(FM_STATE_OVERRIDE="$state" "$FINDINGS" list)
  LINES=$(printf '%s\n' "$LISTED" | grep -c .)
  [ "$LINES" -eq 2 ] || fail "list should show both findings regardless of ack state, got $LINES"
  pass "list shows recent findings regardless of acknowledgement state"
}

test_append_unread_mark_read
test_restart_survives_kill_between_write_and_ack
test_tier_must_be_1_or_2
test_list_shows_recent_regardless_of_read_state
