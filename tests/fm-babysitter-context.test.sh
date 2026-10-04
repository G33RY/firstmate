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

assistant_usage() {  # <path> <used>
  cat > "$1" <<EOF
{"type":"user","message":{"role":"user","content":"please work"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":$2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0},"content":"done"}}
EOF
}

assistant_usage_split() {  # <path>
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":20000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":50000},"content":"done"}}
EOF
}

latest_user_usage() {  # <path>
  cat > "$1" <<'EOF'
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":90000},"content":"done"}}
{"type":"user","message":{"role":"user","content":"new unread prompt"}}
EOF
}

assistant_tool_use_pending() {  # <path>
  cat > "$1" <<'EOF'
{"type":"user","message":{"role":"user","content":"please work"}}
{"type":"assistant","message":{"role":"assistant","model":"claude-test","usage":{"input_tokens":90000},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 600"}}]}}
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
  [ "$used" = 100000 ] || fail "cache tokens were not counted into used tokens: $out"
  [ "$window" = 200000 ] || fail "default window was not chosen for a non-1M model: $out"
  pass "transcript usage counts input plus cache tokens against the context window"
}

test_transcript_usage_found_past_tail_window() {
  local usage_line file out percent
  usage_line="$TMP_ROOT/usage-line.jsonl"
  assistant_usage "$usage_line" 100000
  file="$TMP_ROOT/tail-filler.jsonl"
  cat "$usage_line" > "$file"
  head -c 5000000 /dev/zero | tr '\0' x >> "$file"
  printf '\n' >> "$file"
  out=$(fm_bctx_usage_from_transcript "$file") || fail "usage not found when the newest record is past the tail window"
  percent=${out%%$'\t'*}
  [ "$percent" = 50 ] || fail "expected 50 percent past the tail window, got $out"
  file="$TMP_ROOT/usage-then-filler.jsonl"
  cat "$usage_line" > "$file"
  head -c 5000000 /dev/zero | tr '\0' x >> "$file"
  printf '\n' >> "$file"
  out=$(fm_bctx_usage_from_transcript "$file") || fail "usage not found when a large record follows it"
  percent=${out%%$'\t'*}
  [ "$percent" = 50 ] || fail "expected 50 percent from the full-scan fallback, got $out"
  pass "transcript usage is read from a bounded tail and falls back to a full scan when the tail has no usage row"
}

test_pane_fallback_reads_context_percent() {
  local out
  fm_backend_capture() { printf 'junk line\nContext 42%% used\n'; }
  out=$(fm_bctx_usage_from_pane tmux %1 fm-x) || fail "pane used percentage not parsed"
  [ "${out%%$'\t'*}" = 42 ] || fail "pane used percentage was wrong: $out"
  fm_backend_capture() { printf 'Ctx: 70%% left\n'; }
  out=$(fm_bctx_usage_from_pane tmux %1 fm-x) || fail "pane left percentage not parsed"
  [ "${out%%$'\t'*}" = 30 ] || fail "pane left percentage was not inverted: $out"
  fm_backend_capture() { printf 'no context readout here\n'; }
  fm_bctx_usage_from_pane tmux %1 fm-x >/dev/null && fail "pane fallback invented a percentage"
  pass "pane fallback parses used and left context readouts with portable tools"
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
  assistant_usage "$transcript" 90000
  printf '%s\n' "$transcript" > "$STATE/t1.turn-transcript"
  cat > "$STATE/t1.meta" <<EOF
kind=ship
backend=fake
window=target
worktree=$wt
spawn_gen=gen-1
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
  assistant_usage "$transcript" 90000
  printf '%s\n' "$transcript" > "$STATE/t2.turn-transcript"
  cat > "$STATE/t2.meta" <<EOF
kind=ship
backend=fake
window=target
worktree=$wt
spawn_gen=gen-2
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
  assistant_usage "$transcript" 90000
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=tmux
target=%1
cwd=$home
launch_command=claude --model sonnet
EOF
  fm_backend_foreground_agent_state() {
    if [ -e "$STATE/launched" ]; then printf 'alive'
    elif [ -e "$STATE/exited" ]; then printf 'dead'
    else printf 'alive'; fi
  }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() {
    printf '%s\n' "$3" > "$STATE/exit-command"
    : > "$STATE/exited"
  }
  fm_backend_source() { return 0; }
  fm_backend_tmux_send_literal() { printf '%s\n' "$2" > "$STATE/launch-command"; }
  fm_backend_tmux_send_key() { printf '%s\n' "$2" > "$STATE/launch-key"; : > "$STATE/launched"; }
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

terminal_fakebin() {  # <home> <contents>
  local home=$1 contents=$2 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
  cat > "$fakebin/osascript" <<EOF
#!/usr/bin/env bash
script=\$(cat)
case "\$script" in
  *"return contents of t as text"*) printf '%s\n' "$contents" ;;
  *) printf '%s\n' "\$*" >> "$home/osascript.log" ;;
esac
EOF
  cat > "$fakebin/ps" <<EOF
#!/usr/bin/env bash
[ "\$(cat "$home/osascript.log" 2>/dev/null | wc -l)" -ge 2 ] || exit 0
printf '%s\n' '4242 claude --model sonnet'
EOF
  chmod +x "$fakebin/uname" "$fakebin/osascript" "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_primary_terminal_restart_uses_recorded_tty() {
  local home transcript fakebin terminal_hash dead_pid
  home=$(new_home primary-terminal)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90000
  terminal_hash=$(printf 'same contents' | cksum | awk '{print $1 ":" $2}')
  sleep 0 & dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=terminal
tty=ttys123
pid=$dead_pid
cwd=$home
launch_command=claude --resume old-session
terminal_contents_hash=$terminal_hash
EOF
  fakebin=$(terminal_fakebin "$home" "same contents")
  PATH="$fakebin:$PATH" FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN="$fakebin/osascript" fm_bctx_check_primary 40
  [ "$(sed -n 1p "$home/osascript.log")" = "- ttys123 /exit" ] \
    || fail "Terminal restart did not send /exit to the recorded tty first: $(cat "$home/osascript.log")"
  [ "$(sed -n 2p "$home/osascript.log")" = "- ttys123 cd '$home' && exec claude" ] \
    || fail "Terminal relaunch was not the recorded command with resume flags dropped: $(cat "$home/osascript.log")"
  [ "$(wc -l < "$home/osascript.log")" -eq 2 ] || fail "Terminal restart sent extra commands: $(cat "$home/osascript.log")"
  grep -Fq 'context-relaunch' "$STATE/babysitter-findings.jsonl" \
    || fail "terminal primary restart did not record a relaunch finding"
  pass "primary Terminal.app placement sends exit, waits for the recorded pid, then relaunches without resume flags"
}

test_primary_tmux_restart_without_new_session_alerts_and_retries() {
  local home transcript
  home=$(new_home primary-tmux-no-session)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90000
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=tmux
target=%1
cwd=$home
launch_command=claude
EOF
  fm_backend_foreground_agent_state() {
    if [ -e "$STATE/exited" ]; then printf 'dead'; else printf 'alive'; fi
  }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { : > "$STATE/exited"; }
  fm_backend_source() { return 0; }
  fm_backend_tmux_send_literal() { : > "$STATE/launch-sent"; }
  fm_backend_tmux_send_key() { return 0; }
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  fm_bctx_check_primary 40
  [ -e "$STATE/launch-sent" ] || fail "launch command was not typed after /exit"
  [ ! -e "$STATE/babysitter-context/primary.relaunch" ] || fail "unverified relaunch was recorded as success"
  grep -Fq 'context-relaunch' "$STATE/babysitter-findings.jsonl" 2>/dev/null \
    && fail "unverified relaunch recorded a relaunch finding"
  grep -Fq 'context-alert' "$STATE/babysitter-findings.jsonl" \
    || fail "unverified relaunch did not alert"
  pass "primary tmux relaunch without a new live session alerts and does not record success"
}

test_primary_restart_refuses_flattened_arguments() {
  local home transcript
  home=$(new_home primary-flattened)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90000
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=tmux
target=%1
cwd=$home
launch_command=claude --append-system-prompt Follow AGENTS.md (see docs)
EOF
  fm_backend_foreground_agent_state() { printf 'alive'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf '%s\n' "$3" > "$STATE/exit-command"; }
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  fm_bctx_check_primary 40
  [ ! -e "$STATE/exit-command" ] || fail "primary got /exit for an unreplayable launch command"
  grep -Fq 'restart manually' "$STATE/babysitter-findings.jsonl" \
    || fail "unreplayable launch command did not alert for a manual restart"
  pass "primary with a launch command that flattened quoting alerts for a manual restart without typing anything"
}

test_worker_relaunch_failure_alerts_once_per_generation() {
  local home wt transcript control count
  home=$(new_home worker-alert-dedupe)
  STATE="$home/state"; CONFIG="$home/config"
  wt="$home/wt"
  mkdir -p "$wt"
  transcript="$home/t.jsonl"
  assistant_usage "$transcript" 90000
  printf '%s\n' "$transcript" > "$STATE/t3.turn-transcript"
  cat > "$STATE/t3.meta" <<EOF
kind=ship
backend=fake
window=target
worktree=$wt
spawn_gen=gen-9
EOF
  control="$home/control"
  cat > "$control" <<EOF
#!/usr/bin/env bash
printf 'attempt\n' >> "$home/control.log"
exit 9
EOF
  chmod +x "$control"
  cat > "$home/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: parked · source: run-step · awaiting gate\n'
SH
  chmod +x "$home/crew-state"
  fm_backend_of_meta() { printf 'fake'; }
  fm_backend_target_of_meta() { printf 'target'; }
  fm_backend_agent_state() { printf 'alive'; }
  fm_wake_append() { printf '%s\n' "$2" >> "$STATE/wakes"; }
  for _ in 1 2; do
    FM_BABYSITTER_CONTEXT_CREW_STATE_BIN="$home/crew-state" \
      FM_BABYSITTER_CONTEXT_CONTROL_BIN="$control" fm_bctx_check_worker t3 40
  done
  count=$(wc -l < "$home/control.log")
  [ "$count" -eq 2 ] || fail "failed worker relaunch was not retried on each poll: $count attempts"
  count=$(grep -c 'context-alert' "$STATE/babysitter-findings.jsonl" || true)
  [ "$count" -eq 1 ] || fail "failed worker relaunch appended $count alerts for one generation"
  count=$(wc -l < "$STATE/wakes")
  [ "$count" -eq 1 ] || fail "failed worker relaunch queued $count wakes for one generation"
  pass "a worker whose relaunch keeps failing retries each poll but alerts and wakes once per spawn generation"
}

test_worker_turn_transcript_record_keeps_stop_payload_path() {
  local home record payload
  home=$(new_home turn-transcript)
  record="$home/state/t4.turn-transcript"
  payload='{"session_id":"s-w","transcript_path":"/tmp/worker-transcript.jsonl"}'
  printf '%s' "$payload" | "$ROOT/bin/fm-babysitter-turn-transcript.sh" "$record"
  [ "$(cat "$record")" = /tmp/worker-transcript.jsonl ] \
    || fail "stop payload transcript path was not recorded: $(cat "$record" 2>/dev/null)"
  printf 'not json' | "$ROOT/bin/fm-babysitter-turn-transcript.sh" "$record"
  [ "$(cat "$record")" = /tmp/worker-transcript.jsonl ] \
    || fail "a malformed stop payload overwrote the recorded transcript"
  pass "the worker Stop hook records its payload transcript path and ignores malformed payloads"
}

test_primary_terminal_never_types_launch_into_live_session() {
  local home transcript fakebin terminal_hash live_pid
  home=$(new_home primary-terminal-live)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90000
  terminal_hash=$(printf 'same contents' | cksum | awk '{print $1 ":" $2}')
  sleep 60 & live_pid=$!
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=terminal
tty=ttys123
pid=$live_pid
cwd=$home
launch_command=claude
terminal_contents_hash=$terminal_hash
EOF
  fakebin=$(terminal_fakebin "$home" "same contents")
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  PATH="$fakebin:$PATH" FM_BABYSITTER_CONTEXT_OSASCRIPT_BIN="$fakebin/osascript" fm_bctx_check_primary 40
  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
  [ "$(wc -l < "$home/osascript.log")" -eq 1 ] \
    || fail "launch was typed while the primary still ran: $(cat "$home/osascript.log")"
  grep -Fq '/exit' "$home/osascript.log" || fail "exit was not sent before waiting"
  grep -Fq 'context-alert' "$STATE/babysitter-findings.jsonl" \
    || fail "live primary after exit did not alert"
  grep -Fq 'babysitter-context:primary' "$STATE/wakes" \
    || fail "live primary after exit did not queue a wake"
  pass "primary Terminal.app placement alerts instead of typing the launch command into a live session"
}

test_primary_terminal_alerts_when_tab_changed_since_idle() {
  local home transcript fakebin terminal_hash
  home=$(new_home primary-terminal-changed)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_usage "$transcript" 90000
  terminal_hash=$(printf 'same contents' | cksum | awk '{print $1 ":" $2}')
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
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

test_primary_tool_use_in_flight_is_not_idle() {
  local home transcript
  home=$(new_home primary-tool-in-flight)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  assistant_tool_use_pending "$transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=tmux
target=%1
cwd=$home
launch_command=claude
EOF
  fm_backend_foreground_agent_state() { printf 'alive'; }
  fm_backend_composer_state() { printf 'empty'; }
  fm_backend_send_text_submit() { printf '%s\n' "$3" > "$STATE/exit-command"; }
  fm_backend_source() { return 0; }
  fm_backend_tmux_send_literal() { printf '%s\n' "$2" > "$STATE/launch-command"; }
  fm_backend_tmux_send_key() { return 0; }
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  fm_bctx_check_primary 40
  [ ! -e "$STATE/exit-command" ] || fail "primary got /exit while a tool_use was still unresolved"
  [ ! -e "$STATE/launch-command" ] || fail "primary relaunched while a tool_use was still unresolved"
  [ ! -e "$STATE/wakes" ] || fail "a mid-turn primary queued a wake"
  [ ! -e "$STATE/babysitter-findings.jsonl" ] || fail "a mid-turn primary recorded a finding"
  pass "primary with an unresolved tool_use in its last assistant turn is left alone until idle"
}

test_primary_restart_command_drops_resume_flags() {
  local home command
  home=$(new_home primary-restart-command)
  STATE="$home/state"; CONFIG="$home/config"
  printf 'placement=tmux\ncwd=%s\nlaunch_command=claude --resume abc-123 --model sonnet -c\n' "$home" \
    > "$home/placement"
  command=$(fm_bctx_primary_restart_command "$home/placement") || fail "restart command was refused"
  [ "$command" = "cd '$home' && exec claude --model sonnet" ] \
    || fail "resume/continue flags were not dropped from the relaunch: $command"
  printf 'placement=tmux\ncwd=%s\n' "$home" > "$home/placement-bare"
  fm_bctx_primary_restart_command "$home/placement-bare" >/dev/null \
    && fail "relaunch was guessed without a recorded launch command"
  pass "primary relaunch drops --resume/--continue/-r/-c and alerts when no launch command was recorded"
}

test_primary_defers_when_not_at_idle_boundary() {
  local home transcript
  home=$(new_home primary-defer)
  STATE="$home/state"; CONFIG="$home/config"
  transcript="$home/primary.jsonl"
  latest_user_usage "$transcript"
  printf 'state=idle\nevent=stop\n' > "$STATE/.babysitter-primary-busy"
  cat > "$STATE/.babysitter-primary-placement" <<EOF
transcript=$transcript
placement=tmux
target=%1
cwd=$home
launch_command=claude
EOF
  fm_wake_append() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$STATE/wakes"; }
  fm_bctx_check_primary 40
  [ ! -e "$STATE/launch-command" ] || fail "primary restarted before an idle boundary"
  [ ! -e "$STATE/wakes" ] || fail "primary queued a wake before an idle boundary"
  [ ! -e "$STATE/babysitter-findings.jsonl" ] || fail "primary recorded a finding before an idle boundary"
  pass "primary over threshold but not at an idle boundary does nothing: no restart, finding, or wake"
}

test_primary_relaunch_shape_check() {
  local home
  home=$(new_home primary-shape)
  STATE="$home/state"; CONFIG="$home/config"
  printf 'placement=tmux\ncwd=%s\nlaunch_command=claude --allow-dangerously-skip-permissions --effort high\n' "$home" > "$home/real"
  [ "$(fm_bctx_primary_restart_command "$home/real")" = "cd '$home' && exec claude --allow-dangerously-skip-permissions --effort high" ] \
    || fail "the captain's real primary launch line was refused"
  printf 'placement=tmux\ncwd=%s\nlaunch_command=claude --append-system-prompt Follow AGENTS.md\n' "$home" > "$home/prompt"
  fm_bctx_primary_restart_command "$home/prompt" >/dev/null && fail "a flattened multi-word system prompt was replayed"
  printf 'placement=tmux\ncwd=%s\nlaunch_command=claude --model sonnet Follow up\n' "$home" > "$home/positional"
  fm_bctx_primary_restart_command "$home/positional" >/dev/null && fail "a positional prompt after a flag value was replayed"
  printf 'placement=tmux\ncwd=%s\nlaunch_command=claude -p hello\n' "$home" > "$home/print"
  fm_bctx_primary_restart_command "$home/print" >/dev/null && fail "a free-text print flag was replayed"
  pass "primary relaunch replays the captain's real launch line and refuses flattened free-text arguments"
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
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$home/bin/fm-babysitter-primary-state.sh" idle stop
  grep -Fxq 'state=idle' "$home/state/.babysitter-primary-busy" \
    || fail "primary hook did not record idle: $(cat "$home/state/.babysitter-primary-busy")"
  pass "primary lifecycle hook records busy and idle breadcrumbs in a genuine primary checkout"
}

test_transcript_usage_counts_cache_tokens
test_transcript_usage_found_past_tail_window
test_pane_fallback_reads_context_percent
test_threshold_config_defaults_and_clamps
test_worker_relaunches_once_at_safe_boundary
test_worker_defers_while_working_or_full_gate_locked
test_primary_tmux_restart_at_idle_boundary
test_primary_tool_use_in_flight_is_not_idle
test_primary_restart_command_drops_resume_flags
test_primary_tmux_restart_without_new_session_alerts_and_retries
test_primary_restart_refuses_flattened_arguments
test_worker_relaunch_failure_alerts_once_per_generation
test_worker_turn_transcript_record_keeps_stop_payload_path
test_primary_terminal_restart_uses_recorded_tty
test_primary_terminal_never_types_launch_into_live_session
test_primary_terminal_alerts_when_tab_changed_since_idle
test_primary_defers_when_not_at_idle_boundary
test_primary_relaunch_shape_check
test_primary_state_hook_records_busy_and_idle
