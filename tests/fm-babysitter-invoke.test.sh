#!/usr/bin/env bash
# tests/fm-babysitter-invoke.test.sh - behavior tests for
# bin/fm-babysitter-invoke-lib.sh (docs/babysitter.md "Cadence"): the
# deterministic trigger that actually re-invokes the judge, since nothing else
# ever did. Exercises the real library function against a fake tmux (no real
# window, no real claude process) and fake fm_backend_* overrides, mirroring
# tests/fm-babysitter-liveness.test.sh. Dispatch runs through the real
# bin/fm-send.sh and bin/fm-babysitter-ledger.sh so the durable inbox record
# and ledger cursor behavior are the real thing, not a mock.
# shellcheck disable=SC2016 # Single-quoted bash -c bodies deliberately defer expansion to the inner shell.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-babysitter-invoke-tests)

# A trivial fake tmux good enough for bin/fm-send.sh's tmux delivery path
# (send-keys, capture-pane, ...): every command exits 0, unrecognized ones
# included, so the composer/submit machinery reads an empty-but-healthy pane.
make_fake_tmux() { # <dir>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|set-window-option|kill-window|send-keys) exit 0 ;;
  list-windows) exit 0 ;;
  new-window) printf '@1\n'; exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
}

# new_case <name>: a case dir with the opt-in flag present and a live-looking
# babysitter.meta, since these tests exercise the ENABLED, spawned behavior.
# The opt-in gate itself is covered separately below.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  : > "$dir/config/babysitter-enabled"
  printf 'kind=babysitter\nbackend=tmux\nwindow=firstmate:fm-babysitter\n' > "$dir/state/babysitter.meta"
  printf '%s' "$dir"
}

# run_invoke <dir> <agent-state> [env...]: source the real library with
# fm_backend_agent_state/of_meta/target_of_meta stubbed to <agent-state>
# (mirroring fm-babysitter-liveness.test.sh's stubbing style), so the gate is
# deterministic while dispatch itself still runs for real against fake tmux.
run_invoke() {
  local dir=$1 agent_state=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
    "$@" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    fm_backend_agent_state() { printf "%s" "'"$agent_state"'"; }
    fm_backend_of_meta() { printf "tmux"; }
    fm_backend_target_of_meta() { printf "firstmate:fm-babysitter"; }
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-invoke-lib.sh"
    fm_babysitter_invoke_check
  '
}

count_inbox_msgs() { # <state-dir>
  find "$1/babysitter.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

test_disabled_is_a_true_noop() {
  local dir
  dir="$TMP_ROOT/disabled"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  printf 'kind=babysitter\nbackend=tmux\nwindow=firstmate:fm-babysitter\n' > "$dir/state/babysitter.meta"
  # Deliberately no config/babysitter-enabled and no fake tmux/PATH: any real
  # probe or send attempt would fail loudly by trying the real `tmux`/backend.
  env PATH="/usr/bin:/bin" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-invoke-lib.sh"
    fm_babysitter_invoke_check
  '
  [ ! -d "$dir/state/babysitter.inbox" ] || fail "a disabled home wrote an inbox record anyway"
  pass "without config/babysitter-enabled, the check is a true no-op: nothing probed, nothing dispatched"
}

test_unread_ledger_content_triggers_dispatch() {
  local dir
  dir=$(new_case unread-triggers)
  make_fake_tmux "$dir"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-babysitter-ledger.sh" append --role captain --text "captain said something" \
    >/dev/null || fail "ledger append failed"

  run_invoke "$dir" alive || fail "invoke check failed on unread content"

  [ "$(count_inbox_msgs "$dir/state")" -eq 1 ] || fail "unread ledger content did not dispatch exactly one pass invocation"
  grep -q 'Judge pass' "$dir/state/babysitter.inbox"/*.msg || fail "dispatched record does not point at the Judge pass procedure"
  [ -s "$dir/state/.babysitter-last-invoke" ] || fail "last-invoke marker was not recorded"
  pass "unread ledger content dispatches exactly one judge pass invocation"
}

test_not_alive_never_dispatches() {
  local dir
  dir=$(new_case not-alive)
  make_fake_tmux "$dir"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-babysitter-ledger.sh" append --role captain --text "hello" \
    >/dev/null || fail "ledger append failed"

  run_invoke "$dir" dead || fail "invoke check failed"

  [ "$(count_inbox_msgs "$dir/state")" -eq 0 ] || fail "dispatched a pass to a judge that is not alive"
  pass "a judge that is not reported alive is never sent a pass invocation, even with unread content waiting"
}

test_no_unread_and_no_elapsed_interval_is_quiet() {
  local dir
  dir=$(new_case quiet)
  make_fake_tmux "$dir"

  run_invoke "$dir" alive FM_BABYSITTER_SWEEP_INTERVAL_SECS=1800 || fail "invoke check failed"

  [ "$(count_inbox_msgs "$dir/state")" -eq 0 ] || fail "dispatched a pass with no unread content and no elapsed sweep interval"
  pass "no unread content and an unelapsed sweep interval dispatches nothing"
}

test_elapsed_sweep_interval_triggers_dispatch_with_no_unread() {
  local dir
  dir=$(new_case sweep)
  make_fake_tmux "$dir"
  echo 1 > "$dir/state/.babysitter-last-invoke"

  run_invoke "$dir" alive FM_BABYSITTER_SWEEP_INTERVAL_SECS=1 || fail "invoke check failed"

  [ "$(count_inbox_msgs "$dir/state")" -eq 1 ] || fail "an elapsed sweep interval did not dispatch a pass despite no unread content"
  pass "an elapsed sweep interval dispatches one pass even with an empty ledger, to catch a silent stall"
}

test_in_flight_pass_is_never_overlapped() {
  local dir
  dir=$(new_case busy)
  make_fake_tmux "$dir"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-babysitter-ledger.sh" append --role captain --text "first" \
    >/dev/null || fail "ledger append 1 failed"

  run_invoke "$dir" alive || fail "first invoke check failed"
  [ "$(count_inbox_msgs "$dir/state")" -eq 1 ] || fail "first dispatch did not produce exactly one record"

  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-babysitter-ledger.sh" append --role captain --text "second" \
    >/dev/null || fail "ledger append 2 failed"
  run_invoke "$dir" alive || fail "second invoke check failed"

  [ "$(count_inbox_msgs "$dir/state")" -eq 1 ] || fail "a second pass was dispatched while the first was still unacknowledged"
  pass "an unacknowledged in-flight pass suppresses a second dispatch, even with fresh unread content"
}

test_orphaned_record_recovers_and_unblocks() {
  local dir rec
  dir=$(new_case orphan)
  make_fake_tmux "$dir"
  mkdir -p "$dir/state/babysitter.inbox/handled"
  rec="$dir/state/babysitter.inbox/001.msg"
  printf 'schema=fm-task-inbox.v1\nat=2000-01-01T00:00:00Z\n--\nstale invocation\n' > "$rec"
  touch -t 200001010000 "$rec"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-babysitter-ledger.sh" append --role captain --text "new content" \
    >/dev/null || fail "ledger append failed"

  run_invoke "$dir" alive FM_BABYSITTER_INVOKE_STUCK_SECS=600 || fail "invoke check failed"

  [ -f "$dir/state/babysitter.inbox/handled/001.msg" ] || fail "the orphaned record was not retired into handled/"
  [ "$(count_inbox_msgs "$dir/state")" -eq 1 ] || fail "a fresh pass was not dispatched after the orphan was cleared"
  pass "an unacknowledged record far older than the stuck threshold is retired as orphaned, unblocking a fresh dispatch"
}

test_disabled_is_a_true_noop
test_unread_ledger_content_triggers_dispatch
test_not_alive_never_dispatches
test_no_unread_and_no_elapsed_interval_is_quiet
test_elapsed_sweep_interval_triggers_dispatch_with_no_unread
test_in_flight_pass_is_never_overlapped
test_orphaned_record_recovers_and_unblocks
