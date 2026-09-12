#!/usr/bin/env bash
# tests/fm-afk-supervisor-startup.test.sh - portable regression for
# fm-supervise-daemon.sh's supervisor-pane startup refusal.
#
# Runs the REAL executed daemon binary (fm_super_main, not the sourced pure
# functions other daemon tests exercise) against a private tmux server with
# real processes, mirroring tests/fm-tmux-agent-liveness.test.sh's fixtures and
# tests/fm-afk-inject-e2e.test.sh's live-daemon harness. No herdr and no
# harness credentials needed, so it runs everywhere CI runs tmux.
#
# The defect this guards: an unresolvable supervisor pane used to fall back to
# the literal tmux target "firstmate:0" with only a startup warning, so a
# firstmate not running inside a tracked pane spent an entire away-mode session
# typing escalations into whatever (or nothing) happened to sit at that name.
# This proves the fix end to end:
#   - no FM_SUPERVISOR_TARGET/TMUX_PANE/HERDR_ENV at all -> refuses at startup,
#     releases its lock, and leaves no pidfile (never silently guesses).
#   - an auto-discovered TMUX_PANE that resolves to a bare-shell pane ->
#     refuses too (a pane existing is not the same as a pane running firstmate).
#   - an auto-discovered TMUX_PANE running a real agent process -> starts.
#   - an explicit FM_SUPERVISOR_TARGET override pointing at a bare shell ->
#     still starts: the override is a deliberate escape hatch (also the shape
#     tests/fm-afk-inject-e2e.test.sh's fixture pane relies on) and is exempt
#     from the bare-shell proof.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-super-startup-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-super-startup.XXXXXX")
SESSION=super
DAEMON_PID=

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so the daemon's bare `tmux` calls reach the private
# socket and never touch the host's real sessions.
mkdir -p "$LAB/shim" "$LAB/agentbin"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# A stand-in "harness" binary: a SYMLINK to a real long-running system binary
# (never a copy - a copied platform binary fails code-signing validation and is
# killed on macOS arm64), named so bin/backends/tmux.sh's process classifier
# reads it as a verified agent.
ln -s "$SLEEP_BIN" "$LAB/agentbin/claude-link"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n shellpane -x 80 -y 24 \
  || fail "could not start the private tmux server"
SHELL_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:shellpane" '#{pane_id}')

# Run the agent process DIRECTLY as the window command (not typed into a
# shell), so its identity is unambiguous - the same technique
# fm-tmux-agent-liveness.test.sh uses.
"$REAL_TMUX" -L "$SOCKET" new-window -d -n agentpane -t "$SESSION" \
  "$LAB/agentbin/claude-link" 900 \
  || fail "could not create the agent-pane window"
AGENT_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SESSION:agentpane" '#{pane_id}')
sleep 0.3

new_state() {
  mktemp -d "${TMPDIR:-/tmp}/fm-super-state.XXXXXX"
}

# run_daemon_expect_refusal: launches the daemon expecting it to exit quickly
# and non-zero, with the given extra env applied. Any of TMUX_PANE, HERDR_ENV,
# HERDR_PANE_ID, FM_SUPERVISOR_TARGET, FM_SUPERVISOR_BACKEND ambient in THIS
# test process (e.g. this suite itself running inside tmux or herdr) are
# unset first, so the daemon sees only what the case passes.
run_daemon_expect_refusal() {  # <state> <label> [VAR=val ...]
  local state=$1 label=$2 rc out
  shift 2
  out=$(env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
        -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
        FM_STATE_OVERRIDE="$state" "$@" "$DAEMON" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "$label: daemon exited 0, expected a startup refusal (output: $out)"
  [ ! -e "$state/.supervise-daemon.pid" ] \
    || fail "$label: refused daemon left a pidfile behind"
  [ ! -e "$state/.supervise-daemon.lock" ] \
    || fail "$label: refused daemon left its startup lock held"
  printf '%s' "$out"
}

# run_daemon_expect_start: launches the daemon in the background expecting it
# to pass every startup check and enter its main loop, then returns with
# DAEMON_PID set so the caller (or cleanup_all) can kill it. Polls for the
# "daemon starting" log line rather than the pidfile: the pidfile is written
# right after the startup lock is acquired, BEFORE backend/target discovery
# and this fix's new validation run, so its presence alone does not prove
# those checks passed - only the final startup log line does.
run_daemon_expect_start() {  # <state> <label> [VAR=val ...]
  local state=$1 label=$2 i=0
  shift 2
  env -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
      -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
      FM_STATE_OVERRIDE="$state" "$@" \
      nohup "$DAEMON" >"$state/daemon.out" 2>"$state/daemon.err" &
  DAEMON_PID=$!
  while [ "$i" -lt 50 ]; do
    grep -qF "daemon starting" "$state/.supervise-daemon.log" 2>/dev/null && return 0
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$DAEMON_PID" 2>/dev/null
  fail "$label: daemon did not reach its startup log line (stderr: $(cat "$state/daemon.err" 2>/dev/null))"
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=
}

test_unresolvable_target_refuses() {
  local state out
  state=$(new_state)
  out=$(run_daemon_expect_refusal "$state" "unresolvable")
  case "$out" in
    *"could not resolve firstmate's own supervisor pane"*) ;;
    *) fail "unresolvable: missing the expected refusal message (got: $out)" ;;
  esac
  grep -qF "startup failed: supervisor pane unresolvable" "$state/.supervise-daemon.log" \
    || fail "unresolvable: daemon log missing the startup-failure line"
  rm -rf "$state"
  pass "no FM_SUPERVISOR_TARGET/TMUX_PANE/HERDR_ENV: daemon refuses at startup, no firstmate:0 guess, no leftover lock or pidfile"
}

test_auto_discovered_bare_shell_refuses() {
  local state out
  state=$(new_state)
  out=$(run_daemon_expect_refusal "$state" "auto-discovered bare shell" TMUX_PANE="$SHELL_PANE")
  case "$out" in
    *"is a bare shell, not a firstmate pane"*) ;;
    *) fail "auto-discovered bare shell: missing the expected refusal message (got: $out)" ;;
  esac
  grep -qF "has no agent process" "$state/.supervise-daemon.log" \
    || fail "auto-discovered bare shell: daemon log missing the no-agent-process line"
  rm -rf "$state"
  pass "TMUX_PANE auto-discovered to a bare-shell pane: daemon refuses rather than supervising an empty shell"
}

test_auto_discovered_agent_pane_starts() {
  local state
  state=$(new_state)
  run_daemon_expect_start "$state" "auto-discovered agent pane" TMUX_PANE="$AGENT_PANE"
  grep -qF "daemon starting" "$state/.supervise-daemon.log" \
    || fail "auto-discovered agent pane: daemon log missing the startup line"
  stop_daemon
  rm -rf "$state"
  pass "TMUX_PANE auto-discovered to a real agent pane: daemon starts normally"
}

test_explicit_override_bare_shell_starts() {
  local state
  state=$(new_state)
  run_daemon_expect_start "$state" "explicit override, bare shell" \
    FM_SUPERVISOR_TARGET="$SHELL_PANE" FM_SUPERVISOR_BACKEND=tmux
  grep -qF "daemon starting" "$state/.supervise-daemon.log" \
    || fail "explicit override, bare shell: daemon log missing the startup line"
  stop_daemon
  rm -rf "$state"
  pass "explicit FM_SUPERVISOR_TARGET at a bare-shell pane is exempt from the agent proof and still starts"
}

test_unresolvable_target_refuses
test_auto_discovered_bare_shell_refuses
test_auto_discovered_agent_pane_starts
test_explicit_override_bare_shell_starts

echo "all fm-supervise-daemon.sh supervisor-startup tests passed"
