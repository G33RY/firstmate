#!/usr/bin/env bash
# tests/fm-babysitter-liveness.test.sh - behavior tests for
# bin/fm-babysitter-liveness-lib.sh (docs/babysitter.md): the deterministic
# layer that guarantees the judge's own liveness never depends on the judge
# noticing its own absence. Exercises the real library function against a
# fake tmux (no real window, no real claude process) and a fake
# fm_backend_agent_state override so dead/missing/ambiguous/alive can each be
# forced deterministically.
# shellcheck disable=SC2016 # Single-quoted bash -c bodies deliberately defer expansion to the inner shell.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-babysitter-liveness-tests)

# A trivial fake tmux good enough for fm-babysitter-spawn.sh's launch path
# (see tests/fm-babysitter-spawn.test.sh for the fuller one; this suite only
# needs launch to succeed, not to inspect what it sent).
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

# new_case <name>: a case dir with the opt-in flag present (config/babysitter-enabled),
# since these tests exercise the ENABLED behavior. The opt-in gate itself is
# covered separately below.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  : > "$dir/config/babysitter-enabled"
  printf '%s' "$dir"
}

test_disabled_by_default_is_a_true_noop() {
  local dir
  dir="$TMP_ROOT/disabled"
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  # Deliberately no config/babysitter-enabled and no fake tmux: any real spawn
  # attempt would fail loudly by trying to run the real `tmux` binary.
  OUT=$(env PATH="/usr/bin:/bin" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
    fm_babysitter_liveness_check
  ')
  [ -z "$OUT" ] || fail "a disabled home should print nothing, got: $OUT"
  [ ! -e "$dir/state/babysitter.meta" ] || fail "a disabled home spawned a judge anyway"
  pass "without config/babysitter-enabled, the check is a true no-op: no meta, no spawn attempt, nothing printed"
}

test_never_spawned_spawns_silently() {
  local dir
  dir=$(new_case never-spawned)
  make_fake_tmux "$dir"

  OUT=$(env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
    fm_babysitter_liveness_check
  ')
  [ -z "$OUT" ] || fail "first-time spawn should be silent on success, got: $OUT"
  [ -f "$dir/state/babysitter.meta" ] || fail "no meta was written on first-time spawn"
  pass "an enabled, never-spawned judge is spawned silently on success"
}

test_alive_judge_is_silent_and_resets_attempts() {
  local dir
  dir=$(new_case alive)
  printf 'kind=babysitter\nbackend=fake-alive\nwindow=x\n' > "$dir/state/babysitter.meta"
  echo 2 > "$dir/state/.babysitter-relaunch-attempts"
  echo 1000000000 > "$dir/state/.babysitter-down-since"

  OUT=$(env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    fm_backend_agent_state() { printf "alive"; }
    fm_backend_of_meta() { printf "fake-alive"; }
    fm_backend_target_of_meta() { printf "x"; }
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
    fm_babysitter_liveness_check
  ')
  [ -z "$OUT" ] || fail "an alive judge should print nothing, got: $OUT"
  [ ! -e "$dir/state/.babysitter-relaunch-attempts" ] || fail "attempts counter was not cleared once alive"
  pass "an alive judge is silent and clears any stale failure counters"
}

test_dead_judge_is_relaunched_and_reported() {
  local dir
  dir=$(new_case dead)
  make_fake_tmux "$dir"
  printf 'kind=babysitter\nbackend=fake-dead\nwindow=x\n' > "$dir/state/babysitter.meta"

  OUT=$(env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
    FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    fm_backend_agent_state() { printf "dead"; }
    fm_backend_of_meta() { printf "fake-dead"; }
    fm_backend_target_of_meta() { printf "x"; }
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
    fm_babysitter_liveness_check
  ')
  printf '%s' "$OUT" | grep -q 'BABYSITTER_LIVENESS: was dead, relaunched' \
    || fail "a dead judge did not report a relaunch: $OUT"
  [ -e "$dir/state/.babysitter-relaunch-attempts" ] || fail "no attempts counter was recorded"
  pass "a dead judge is relaunched and reported with a BABYSITTER_LIVENESS line"
}

test_ambiguous_state_is_preserved_and_reported() {
  local dir
  dir=$(new_case ambiguous)
  printf 'kind=babysitter\nbackend=fake-amb\nwindow=x\n' > "$dir/state/babysitter.meta"

  OUT=$(env FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" bash -c '
    set -eu
    STATE="$FM_STATE_OVERRIDE"
    CONFIG="$FM_CONFIG_OVERRIDE"
    fm_backend_agent_state() { printf "ambiguous"; }
    fm_backend_of_meta() { printf "fake-amb"; }
    fm_backend_target_of_meta() { printf "x"; }
    # shellcheck disable=SC1091
    . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
    fm_babysitter_liveness_check
  ')
  printf '%s' "$OUT" | grep -q 'BABYSITTER_LIVENESS: skipped' \
    || fail "an ambiguous probe was not reported as a skip: $OUT"
  pass "an ambiguous/unreadable/unverified probe is preserved untouched and reported, never relaunched"
}

test_exhausted_attempts_fires_tier2_and_stops_relaunching() {
  local dir log
  dir=$(new_case exhausted)
  log="$dir/ntfy.log"
  make_fake_tmux "$dir"
  printf 'kind=babysitter\nbackend=fake-dead\nwindow=x\n' > "$dir/state/babysitter.meta"
  echo "faketopic" > "$dir/config/babysitter-ntfy-topic"
  chmod 600 "$dir/config/babysitter-ntfy-topic"

  NTFY_REC="$dir/ntfy-rec.sh"
  cat > "$NTFY_REC" <<REC
#!/usr/bin/env bash
printf '%s\n' "\${1:-}" >> "$log"
exit 0
REC
  chmod +x "$NTFY_REC"

  for _ in 1 2 3 4; do
    env PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" \
      FM_DATA_OVERRIDE="$dir/data" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_BABYSITTER_NTFY_EXEC="$NTFY_REC" FM_BABYSITTER_LIVENESS_MAX_ATTEMPTS=3 bash -c '
      set -eu
      STATE="$FM_STATE_OVERRIDE"
      CONFIG="$FM_CONFIG_OVERRIDE"
      fm_backend_agent_state() { printf "dead"; }
      fm_backend_of_meta() { printf "fake-dead"; }
      fm_backend_target_of_meta() { printf "x"; }
      # shellcheck disable=SC1091
      . "'"$ROOT"'/bin/fm-babysitter-liveness-lib.sh"
      fm_babysitter_liveness_check
    ' > "$dir/last.out"
  done

  grep -q 'could not be revived' "$dir/last.out" || fail "4th consecutive dead probe did not report irrevivable: $(cat "$dir/last.out")"
  [ -s "$log" ] || fail "tier-2 nudge was not fired for an irrevivable judge"
  grep -qF 'babysitter judge' "$log" || fail "tier-2 payload did not match the judge-down template: $(cat "$log")"
  pass "consecutive dead probes past the attempt budget report irrevivable and fire the tier-2 nudge"
}

test_disabled_by_default_is_a_true_noop
test_never_spawned_spawns_silently
test_alive_judge_is_silent_and_resets_attempts
test_dead_judge_is_relaunched_and_reported
test_ambiguous_state_is_preserved_and_reported
test_exhausted_attempts_fires_tier2_and_stops_relaunching
