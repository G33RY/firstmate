#!/usr/bin/env bash
# tests/fm-wake-drain-parked-checkpoint.test.sh - behavior tests for the PARKED
# AT CHECKPOINT section bin/fm-wake-drain.sh prints on every drain
# (docs/babysitter.md). A mode=no-mistakes ship task whose latest status line
# is a bare done: (no PR URL) committed and is now idle waiting on firstmate to
# trigger /no-mistakes - a deliberate handoff, not a stuck worker. These tests
# exercise the real drain script over crafted meta/status fixtures and assert
# on its printed output and side effects (the queued wake, the tier-2 nudge),
# never on the detector's own source text.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-parked-checkpoint-tests)

write_meta() { # <state> <id> <kind> <mode>
  printf 'kind=%s\nmode=%s\n' "$3" "$4" > "$1/$2.meta"
}

test_parked_ship_task_is_surfaced() {
  local dir state out
  dir=$(make_case parked)
  state="$dir/state"
  out="$dir/drain.out"
  write_meta "$state" task1 ship no-mistakes
  printf 'working: implementing the fix\n' > "$state/task1.status"
  printf 'done: implemented the auth fix, committed abc1234\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a parked no-mistakes task"

  grep -F 'PARKED AT CHECKPOINT' "$out" >/dev/null || fail "parked task produced no PARKED AT CHECKPOINT section"
  grep -F 'task1' "$out" | grep -F 'implemented the auth fix' >/dev/null \
    || fail "parked task was not surfaced with its id and status line"
  grep -F 'trigger /no-mistakes' "$out" >/dev/null || fail "section is missing the trigger hint"
  pass "a mode=no-mistakes ship task parked at a bare done: line is surfaced as PARKED AT CHECKPOINT"
}

test_parked_task_queues_a_durable_wake() {
  local dir state out
  dir=$(make_case parked-wake)
  state="$dir/state"
  out="$dir/drain.out"
  write_meta "$state" task2 ship no-mistakes
  printf 'done: implemented the fix, committed def5678\n' > "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a parked task"

  grep -F $'\tcheck\tparked:task2\t' "$state/.wake-queue" >/dev/null \
    || fail "no durable check: wake was queued for the parked task: $(cat "$state/.wake-queue" 2>/dev/null)"
  [ -e "$state/.parked-notified-task2" ] || fail "no idempotency marker was written for the parked task"

  # A second drain must not queue a second wake for the same still-parked task.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"
  QUEUED=$(grep -cF $'\tcheck\tparked:task2\t' "$state/.wake-queue")
  [ "$QUEUED" -eq 1 ] || fail "a second drain re-queued the wake for an already-notified parked task (count=$QUEUED)"
  pass "a newly-parked task queues exactly one durable check: wake, idempotent across drains"
}

test_landed_pr_line_is_not_parked() {
  local dir state out
  dir=$(make_case landed)
  state="$dir/state"
  out="$dir/drain.out"
  write_meta "$state" task3 ship no-mistakes
  printf 'done: PR https://github.com/example/repo/pull/1 checks green\n' > "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a landed task"

  if grep -F 'PARKED AT CHECKPOINT' "$out" >/dev/null; then
    fail "a done: line naming a PR URL was misread as parked: $(cat "$out")"
  fi
  pass "a done: PR <url> line (already handed to /no-mistakes) is never read as parked"
}

test_working_line_clears_the_marker() {
  local dir state out
  dir=$(make_case clears)
  state="$dir/state"
  out="$dir/drain.out"
  write_meta "$state" task4 ship no-mistakes
  printf 'done: implemented the fix, committed cafefeed\n' > "$state/task4.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  [ -e "$state/.parked-notified-task4" ] || fail "marker was not written on first detection"

  # Firstmate triggers validation; the worker appends further status.
  printf 'working: no-mistakes running\n' >> "$state/task4.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "second drain failed"

  if grep -F 'PARKED AT CHECKPOINT' "$out" >/dev/null; then
    fail "task no longer at the bare done: line still read as parked: $(cat "$out")"
  fi
  [ ! -e "$state/.parked-notified-task4" ] || fail "idempotency marker was not cleared once the task stopped being parked"
  pass "a later status line self-clears the parked state and its marker"
}

test_direct_pr_mode_is_never_parked() {
  local dir state out
  dir=$(make_case direct-pr)
  state="$dir/state"
  out="$dir/drain.out"
  write_meta "$state" task5 ship direct-PR
  printf 'done: implemented the fix, committed 1234abc\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a direct-PR task"

  if grep -F 'PARKED AT CHECKPOINT' "$out" >/dev/null; then
    fail "a direct-PR task (no firstmate-triggered checkpoint) was read as parked: $(cat "$out")"
  fi
  pass "only mode=no-mistakes ship tasks are ever read as parked"
}

test_long_wait_fires_tier2_nudge_with_no_task_content() {
  local dir state out log
  dir=$(make_case tier2)
  state="$dir/state"
  out="$dir/drain.out"
  log="$dir/ntfy.log"
  write_meta "$state" secret-project-task ship no-mistakes
  printf 'done: implemented the fix, committed feedcafe\n' > "$state/secret-project-task.status"
  # Back-date the status file so its age exceeds the tier-2 threshold.
  OLD=$(( $(date +%s) - 3600 ))
  touch -t "$(date -r "$OLD" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$OLD" +%Y%m%d%H%M.%S)" "$state/secret-project-task.status" 2>/dev/null \
    || fail "could not back-date the fixture status file"

  mkdir -p "$dir/config"
  echo "faketopic" > "$dir/config/babysitter-ntfy-topic"
  chmod 600 "$dir/config/babysitter-ntfy-topic"

  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_BABYSITTER_NTFY_LOG="$log" FM_BABYSITTER_PARKED_TIER2_SECS=60 \
    "$DRAIN" > "$out" || fail "drain failed on a long-parked task"

  [ -s "$log" ] || fail "tier-2 nudge was not fired for a long-parked task"
  grep -F 'secret-project-task' "$log" >/dev/null && fail "tier-2 payload leaked the task id"
  grep -Eiq '^Firstmate: [0-9]+ task\(s\) parked awaiting validation, oldest [0-9]+s - check the terminal\.$' "$log" \
    || fail "tier-2 payload did not match the fixed content-restricted template: $(cat "$log")"
  pass "a task parked past the tier-2 threshold fires the ntfy nudge with only counts, never task content"
}

test_parked_ship_task_is_surfaced
test_parked_task_queues_a_durable_wake
test_landed_pr_line_is_not_parked
test_working_line_clears_the_marker
test_direct_pr_mode_is_never_parked
test_long_wait_fires_tier2_nudge_with_no_task_content
