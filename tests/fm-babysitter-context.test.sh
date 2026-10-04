#!/usr/bin/env bash
# Behavior tests for bin/fm-babysitter-context-lib.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=bin/fm-babysitter-context-lib.sh
. "$ROOT/bin/fm-babysitter-context-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-babysitter-context)
FM_BABYSITTER_CONTEXT_FULL_GATE_LOCK="$TMP_ROOT/no-full-gate.lock"

new_home() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data"
  : > "$dir/config/babysitter-enabled"
  printf '%s\n' "$dir"
}

assistant_usage() {  # <path> <used> <window>
  cat > "$1" <<EOF
{"type":"user","message":{"role":"user","content":"please work"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":$2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"context_window":$3},"content":"done"}}
EOF
}

assistant_usage_split() {  # <path>
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":50,"context_window":200},"content":"done"}}
EOF
}

latest_user_usage() {  # <path>
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":100,"context_window":200},"content":"done"}}
{"type":"user","message":{"role":"user","content":"new unread prompt"}}
EOF
}

test_transcript_usage_counts_cache_tokens() {
  local file out percent used window
  file="$TMP_ROOT/usage.jsonl"
  assistant_usage_split "$file"
  out=$(fm_bctx_usage_from_transcript "$file") || fail "usage parse failed"
  IFS=$'\t' read -r percent used window _model _source <<EOF
$out
EOF
  [ "$percent" = 50 ] || fail "expected 50 percent, got $percent from $out"
  [ "$used" = 100 ] || fail "cache tokens were not counted into used tokens: $out"
  [ "$window" = 200 ] || fail "context window was not read from usage: $out"
  pass "transcript usage counts input plus cache tokens against the context window"
}

test_threshold_config_defaults_and_clamps() {
  local home
  home=$(new_home threshold)
  STATE="$home/state"; CONFIG="$home/config"
  [ "$(fm_bctx_threshold_percent)" = 40 ] || fail "absent threshold did not default to 40"
  printf '150\n' > "$CONFIG/babysitter-context-threshold-percent"
  [ "$(fm_bctx_threshold_percent)" = 100 ] || fail "threshold did not clamp to 100"
  printf 'abc\n' > "$CONFIG/babysitter-context-threshold-percent"
  [ "$(fm_bctx_threshold_percent)" = 40 ] || fail "invalid threshold did not default to 40"
  pass "threshold config defaults, rejects invalid values, and clamps high values"
}

test_worker_relaunches_once_at_safe_boundary() {
  local home wt transcript crew control count
  home=$(new_home worker-relaunch)
  STATE="$home/state"; CONFIG="$home/config"
  wt="$home/wt"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" config user.email test@example.com
  git -C "$wt" config user.name Test
  touch "$wt/file"
  git -C "$wt" add file
  git -C "$wt" commit -q -m init
  transcript="$home/t.jsonl"
  assistant_usage "$transcript" 90 100
  cat > "$STATE/t1.meta" <<EOF
kind=ship
backend=fake
window=target
worktree=$wt
spawn_gen=gen-1
transcript=$transcript
EOF
  printf 'working: implementation underway\n' > "$STATE/t1.status"
  crew="$home/crew-state"
  control="$home/control"
  cat > "$crew" <<'SH'
#!/usr/bin/env bash
printf 'state: parked · source: run-step · awaiting gate\n'
SH
  chmod +x "$crew"
  cat > "$control" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/control.log"
EOF
  chmod +x "$control"
  fm_backend_of_meta() { printf 'fake'; }
  fm_backend_target_of_meta() { grep '^window=' "$1" | cut -d= -f2-; }
  fm_backend_agent_state() { printf 'alive'; }
  FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$crew" \
    FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t1 40
  FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$crew" \
    FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t1 40
  count=$(wc -l < "$home/control.log")
  [ "$count" -eq 1 ] || fail "worker relaunch was not rate-limited to one per generation: $count"
  grep -Fq 't1 relaunch --note Context threshold reached' "$home/control.log" \
    || fail "relaunch did not go through fm-control shape: $(cat "$home/control.log")"
  grep -Fq 'latest_status=working: implementation underway' "$home/control.log" \
    || fail "progress note did not include durable status: $(cat "$home/control.log")"
  pass "an over-threshold worker relaunches once at a parked boundary with a durable progress note"
}

test_worker_defers_while_working_or_full_gate_locked() {
  local home wt transcript crew control fakebin global_lock
  home=$(new_home worker-defer)
  STATE="$home/state"; CONFIG="$home/config"
  wt="$home/wt"
  mkdir -p "$wt/.no-mistakes"
  transcript="$home/t.jsonl"
  assistant_usage "$transcript" 90 100
  cat > "$STATE/t2.meta" <<EOF
kind=ship
backend=fake
window=target
worktree=$wt
spawn_gen=gen-2
transcript=$transcript
EOF
  crew="$home/crew-state"
  control="$home/control"
  cat > "$crew" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · fixing\n'
SH
  chmod +x "$crew"
  cat > "$control" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$control"
  fm_backend_of_meta() { printf 'fake'; }
  fm_backend_target_of_meta() { grep '^window=' "$1" | cut -d= -f2-; }
  fm_backend_agent_state() { printf 'alive'; }
  FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$crew" \
    FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t2 40
  [ ! -e "$STATE/babysitter-context/t2.relaunch" ] || fail "working worker was relaunched"
  grep -Fq 'context-deferred' "$STATE/babysitter-findings.jsonl" \
    || fail "working defer did not record a finding"

  cat > "$crew" <<'SH'
#!/usr/bin/env bash
printf 'state: parked · source: run-step · awaiting gate\n'
SH
  : > "$wt/.no-mistakes/full-gate.lock"
  printf 'gen-3\n' >> "$STATE/t2.meta"
  sed -i.bak 's/spawn_gen=gen-2/spawn_gen=gen-3/' "$STATE/t2.meta"
  rm -f "$STATE/babysitter-context/t2.deferred"
  FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$crew" \
    FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t2 40
  [ ! -e "$STATE/babysitter-context/t2.relaunch" ] || fail "full-gate worker was relaunched"
  grep -Fq 'full-gate lock is present' "$STATE/babysitter-findings.jsonl" \
    || fail "full-gate defer did not record the reason"

  rm -f "$STATE/babysitter-context/t2.full-gate" "$wt/.no-mistakes/full-gate.lock"
  global_lock="$home/global-full-gate.lock"
  : > "$global_lock"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/lockf" <<'SH'
#!/usr/bin/env bash
exit 75
SH
  chmod +x "$fakebin/lockf"
  sed -i.bak 's/spawn_gen=gen-3/spawn_gen=gen-4/' "$STATE/t2.meta"
  PATH="$fakebin:$PATH" FM_BABYSITTER_CONTEXT_FULL_GATE_LOCK="$global_lock" \
    FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$crew" \
    FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t2 40
  [ ! -e "$STATE/babysitter-context/t2.relaunch" ] || fail "global full-gate worker was relaunched"
  grep -Fq 'full-gate lock is present' "$STATE/babysitter-findings.jsonl" \
    || fail "global full-gate defer did not record the reason"
  pass "worker relaunch defers while working and while a full-gate lock is present"
}

test_primary_tmux_restart_at_idle_boundary() {
  local home transcript launch
  home=$(new_home primary-tmux)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90 100
  printf 's1\t%s\n' "$transcript" > "$STATE/.babysitter-primary-transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
placement=tmux
target=%1
cwd=$home
launch_command=claude --model sonnet
EOF
  fm_backend_foreground_agent_state() {
    [ -e "$STATE/exited" ] && printf 'dead' || printf 'alive'
  }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() {
    printf '%s\n' "$3" > "$STATE/exit-command"
    : > "$STATE/exited"
  }
  fm_backend_source() { return 0; }
  fm_backend_tmux_send_literal() { printf '%s\n' "$2" > "$STATE/launch-command"; }
  fm_backend_tmux_send_key() { printf '%s\n' "$2" > "$STATE/launch-key"; }
  fm_bctx_check_primary 40
  grep -Fxq /exit "$STATE/exit-command" || fail "tmux restart did not send /exit"
  launch=$(cat "$STATE/launch-command")
  [ "$launch" = "cd '$home' && exec claude --model sonnet" ] \
    || fail "tmux restart launch command was wrong: $launch"
  grep -Fxq Enter "$STATE/launch-key" || fail "tmux restart did not submit the launch command"
  grep -Fq 'context-relaunch' "$STATE/babysitter-findings.jsonl" \
    || fail "primary restart did not record a relaunch finding"
  pass "primary tmux placement exits and relaunches at a proven idle boundary"
}

test_primary_terminal_restart_uses_recorded_tty() {
  local home transcript fakebin args terminal_hash
  home=$(new_home primary-terminal)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90 100
  terminal_hash=$(printf 'same contents' | cksum | awk '{print $1 ":" $2}')
  printf 's1\t%s\n' "$transcript" > "$STATE/.babysitter-primary-transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
placement=terminal
tty=ttys123
cwd=$home
launch_command=claude
terminal_contents_hash=$terminal_hash
EOF
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/osascript" <<EOF
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *"return contents of t as text"*) printf '%s\n' "same contents" ;;
  *) printf '%s\n' "\$*" > "$home/osascript.args" ;;
esac
EOF
  chmod +x "$fakebin/uname" "$fakebin/osascript"
  PATH="$fakebin:$PATH" FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN="$fakebin/osascript" fm_bctx_check_primary 40
  args=$(cat "$home/osascript.args")
  case "$args" in
    *"ttys123"*" /exit "*"cd '$home' && exec claude"*) ;;
    *) fail "Terminal restart did not target the recorded tty with exit and launch commands: $args" ;;
  esac
  grep -Fq 'context-relaunch' "$STATE/babysitter-findings.jsonl" \
    || fail "terminal primary restart did not record a relaunch finding"
  pass "primary Terminal.app placement restarts through the recorded tty and launch command"
}

test_primary_terminal_alerts_when_tab_changed_since_idle() {
  local home transcript fakebin terminal_hash
  home=$(new_home primary-terminal-changed)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90 100
  terminal_hash=$(printf 'same contents' | cksum | awk '{print $1 ":" $2}')
  printf 's1\t%s\n' "$transcript" > "$STATE/.babysitter-primary-transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
placement=terminal
tty=ttys123
cwd=$home
launch_command=claude
terminal_contents_hash=$terminal_hash
EOF
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/osascript" <<EOF
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *"return contents of t as text"*) printf '%s\n' "typed draft" ;;
  *) printf '%s\n' "\$*" > "$home/osascript.args" ;;
esac
EOF
  chmod +x "$fakebin/uname" "$fakebin/osascript"
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  PATH="$fakebin:$PATH" FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN="$fakebin/osascript" fm_bctx_check_primary 40
  [ ! -e "$home/osascript.args" ] || fail "Terminal restart ran despite changed tab contents"
  grep -Fq 'context-alert' "$STATE/babysitter-findings.jsonl" \
    || fail "changed Terminal contents did not alert"
  grep -Fq 'babysitter-context:primary' "$STATE/wakes" \
    || fail "changed Terminal contents did not queue a wake"
  pass "primary Terminal.app placement alerts when tab contents changed since the idle breadcrumb"
}

test_primary_alerts_when_unread_or_busy() {
  local home transcript
  home=$(new_home primary-alert)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  latest_user_usage "$transcript"
  printf 's1\t%s\n' "$transcript" > "$STATE/.babysitter-primary-transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
placement=tmux
target=%1
cwd=$home
launch_command=claude
EOF
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  fm_bctx_check_primary 40
  [ ! -e "$STATE/launch-command" ] || fail "primary restarted despite an unread user transcript tail"
  grep -Fq 'context-alert' "$STATE/babysitter-findings.jsonl" \
    || fail "unread primary tail did not alert"
  grep -Fq 'babysitter-context:primary' "$STATE/wakes" \
    || fail "unread primary tail did not queue a wake"
  pass "primary over-threshold condition alerts instead of restarting when no safe idle boundary is proven"
}

test_primary_state_hook_records_busy_and_idle() {
  local home payload
  home=$(new_home primary-state-hook)
  mkdir -p "$home/bin"
  touch "$home/AGENTS.md"
  cp "$ROOT/bin/fm-babysitter-primary-state.sh" "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-hook-host-lib.sh" "$home/bin/"
  git -C "$home" init -q
  payload='{"session_id":"s-hook","transcript_path":"'"$home"'/transcript.jsonl"}'
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-babysitter-primary-state.sh" busy user-prompt-submit
  grep -Fxq 'state=busy' "$home/state/.babysitter-primary-busy" \
    || fail "primary hook did not record busy: $(cat "$home/state/.babysitter-primary-busy")"
  grep -Fxq 'session_id=s-hook' "$home/state/.babysitter-primary-busy" \
    || fail "primary hook did not preserve session id"
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-babysitter-primary-state.sh" idle stop
  grep -Fxq 'state=idle' "$home/state/.babysitter-primary-busy" \
    || fail "primary hook did not record idle: $(cat "$home/state/.babysitter-primary-busy")"
  pass "primary lifecycle hook records busy and idle breadcrumbs in a genuine primary checkout"
}

test_transcript_usage_counts_cache_tokens
test_threshold_config_defaults_and_clamps
test_worker_relaunches_once_at_safe_boundary
test_worker_defers_while_working_or_full_gate_locked
test_primary_tmux_restart_at_idle_boundary
test_primary_terminal_restart_uses_recorded_tty
test_primary_terminal_alerts_when_tab_changed_since_idle
test_primary_alerts_when_unread_or_busy
test_primary_state_hook_records_busy_and_idle
