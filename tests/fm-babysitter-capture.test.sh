#!/usr/bin/env bash
# tests/fm-babysitter-capture.test.sh - behavior tests for
# bin/fm-babysitter-capture.sh (docs/babysitter.md): primary-scope gating,
# cursor replay/re-anchor, the never-block property, and captain-text
# exclusion filters. Exercises the real hook script over a real transcript
# fixture and a real git-initialized sandbox.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-babysitter-capture-tests)

# make_primary_case <name>: a genuine primary checkout (plain git repo with
# AGENTS.md and bin/) that fm_primary_scope_matches accepts.
make_primary_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/bin"
  touch "$dir/AGENTS.md"
  cp "$ROOT"/bin/fm-babysitter-*.sh "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-hook-host-lib.sh \
    "$ROOT"/bin/fm-wake-lib.sh "$ROOT"/bin/fm-operational-input.sh "$ROOT"/bin/fm-line-cap-lib.sh "$dir/bin/"
  (cd "$dir" && git init -q)
  printf '%s' "$dir"
}

payload_for() { # <session-id> <transcript-path>
  printf '{"session_id":"%s","transcript_path":"%s"}' "$1" "$2"
}

test_captures_captain_and_firstmate_text_only() {
  local dir transcript
  dir=$(make_primary_case basic)
  transcript="$dir/transcript.jsonl"
  cat > "$transcript" <<'EOF'
{"type":"user","isSidechain":false,"message":{"role":"user","content":"please fix the auth bug now"}}
{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Bash","input":{}},{"type":"text","text":"Aye captain, working on it now."}]}}
{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","content":"some tool output"}]}}
{"type":"user","isSidechain":true,"message":{"role":"user","content":"sub-agent chatter must never appear"}}
EOF
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"
  RC=$?
  [ "$RC" -eq 0 ] || fail "capture exited nonzero: $RC"

  LEDGER="$dir/state/babysitter-ledger.jsonl"
  [ -f "$LEDGER" ] || fail "no ledger was written"
  grep -qF '"role":"captain","text":"please fix the auth bug now"' "$LEDGER" || fail "captain text was not captured"
  grep -qF '"role":"firstmate","text":"Aye captain, working on it now."' "$LEDGER" || fail "firstmate text was not captured"
  grep -qF 'tool output' "$LEDGER" && fail "a tool_result block leaked into the ledger"
  grep -qF 'sub-agent chatter' "$LEDGER" && fail "a sidechain message leaked into the ledger"
  grep -qF 'hmm' "$LEDGER" && fail "a thinking block leaked into the ledger"
  pass "only captain and firstmate plain text is captured, never tool calls, tool results, thinking, or sidechain"
}

test_excludes_operational_injection_and_synthetic_wrappers() {
  local dir transcript mark
  dir=$(make_primary_case filters)
  transcript="$dir/transcript.jsonl"
  mark=$(printf '\xE2\x81\xA3')
  {
    printf '{"type":"user","isSidechain":false,"message":{"role":"user","content":"%sFIRSTMATE_OP: v1 session-start: run session start"}}\n' "$mark"
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<bash-input>ls</bash-input>"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<bash-stdout>total 0</bash-stdout>"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"<local-command-caveat>Caveat: generated</local-command-caveat>"}}'
    printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"a genuine captain message"}}'
  } > "$transcript"
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"

  LEDGER="$dir/state/babysitter-ledger.jsonl"
  [ -f "$LEDGER" ] || fail "no ledger was written"
  LINES=$(wc -l < "$LEDGER")
  [ "$LINES" -eq 1 ] || fail "expected exactly 1 captured line, got $LINES: $(cat "$LEDGER")"
  grep -qF 'a genuine captain message' "$LEDGER" || fail "the one genuine message was not captured"
  grep -qF 'FIRSTMATE_OP' "$LEDGER" && fail "an operational injection leaked into the ledger"
  grep -qF 'bash-input' "$LEDGER" && fail "a bash-input synthetic wrapper leaked into the ledger"
  pass "operational injections and CLI synthetic wrapper turns are excluded"
}

test_incremental_replay_and_dedup() {
  local dir transcript
  dir=$(make_primary_case incremental)
  transcript="$dir/transcript.jsonl"
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"first message"}}' > "$transcript"
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"
  LEDGER="$dir/state/babysitter-ledger.jsonl"
  LINES=$(wc -l < "$LEDGER")
  [ "$LINES" -eq 1 ] || fail "a second pass with no new content re-captured the same line (count=$LINES)"

  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"second message"}}' >> "$transcript"
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"
  LINES=$(wc -l < "$LEDGER")
  [ "$LINES" -eq 2 ] || fail "appended transcript content was not captured incrementally (count=$LINES)"
  pass "a replayed pass captures nothing new; new transcript content is captured incrementally"
}

test_new_session_reanchors_cursor() {
  local dir transcript1 transcript2
  dir=$(make_primary_case reanchor)
  transcript1="$dir/t1.jsonl"
  transcript2="$dir/t2.jsonl"
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"session one message"}}' > "$transcript1"
  payload_for s1 "$transcript1" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"

  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"session two message"}}' > "$transcript2"
  payload_for s2 "$transcript2" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"

  CURSOR="$dir/state/.babysitter-transcript-cursor"
  grep -qF 's2' "$CURSOR" || fail "cursor did not re-anchor to the new session id: $(cat "$CURSOR")"
  grep -qF 'session two message' "$dir/state/babysitter-ledger.jsonl" || fail "the new session's message was not captured after re-anchor"
  pass "a new session_id re-anchors the transcript cursor and captures the new session's own content"
}

test_crewmate_worktree_is_a_silent_noop() {
  local dir transcript
  dir="$TMP_ROOT/crewmate"
  mkdir -p "$dir/state" "$dir/bin"
  # Deliberately no AGENTS.md and no git init: fm_primary_scope_matches must refuse.
  cp "$ROOT"/bin/fm-babysitter-*.sh "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-hook-host-lib.sh \
    "$ROOT"/bin/fm-wake-lib.sh "$ROOT"/bin/fm-operational-input.sh "$ROOT"/bin/fm-line-cap-lib.sh "$dir/bin/"
  transcript="$dir/transcript.jsonl"
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"never captured"}}' > "$transcript"

  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh"
  RC=$?
  [ "$RC" -eq 0 ] || fail "hook exited nonzero in a non-primary scope: $RC"
  [ -f "$dir/state/babysitter-ledger.jsonl" ] && fail "a non-primary (crewmate-shaped) worktree was captured"
  pass "a worktree with no primary marker (crewmate/scout shape) is a silent no-op"
}

test_never_blocks_on_failure_modes() {
  local dir
  dir=$(make_primary_case failures)

  RC=0
  printf '' | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh" || RC=$?
  [ "$RC" -eq 0 ] || fail "empty stdin did not exit 0 (got $RC)"

  RC=0
  printf 'not valid json {{{' | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh" || RC=$?
  [ "$RC" -eq 0 ] || fail "malformed JSON payload did not exit 0 (got $RC)"

  RC=0
  payload_for s1 "/no/such/transcript.jsonl" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh" || RC=$?
  [ "$RC" -eq 0 ] || fail "a missing transcript did not exit 0 (got $RC)"

  # An unreadable/torn cursor must not block either - just re-anchor.
  transcript="$dir/t.jsonl"
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"after a torn cursor"}}' > "$transcript"
  printf 'garbage-not-tab-separated' > "$dir/state/.babysitter-transcript-cursor"
  RC=0
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh" || RC=$?
  [ "$RC" -eq 0 ] || fail "a malformed cursor did not exit 0 (got $RC)"

  # Lock contention: a held (non-stale) lock must never be waited on.
  LOCKDIR="$dir/state/.babysitter-capture.lock"
  mkdir -p "$LOCKDIR"
  echo "$$" > "$LOCKDIR/pid"
  START=$(date +%s)
  RC=0
  payload_for s1 "$transcript" | FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" "$dir/bin/fm-babysitter-capture.sh" || RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  [ "$RC" -eq 0 ] || fail "lock contention did not exit 0 (got $RC)"
  [ "$ELAPSED" -lt 5 ] || fail "lock contention blocked for ${ELAPSED}s instead of skipping immediately"
  rm -rf "$LOCKDIR"

  pass "empty stdin, malformed payload, missing transcript, a torn cursor, and lock contention all exit 0 without blocking"
}

test_never_blocks_when_temp_writes_fail() {
  local dir transcript readonly_tmp rc
  dir=$(make_primary_case fulldisk)
  transcript="$dir/t.jsonl"
  printf '%s\n' '{"type":"user","isSidechain":false,"message":{"role":"user","content":"disk full case"}}' > "$transcript"
  # A read-only TMPDIR makes every mktemp call fail, simulating a full disk
  # for the hook's temp-file writes without needing a real full filesystem.
  readonly_tmp="$dir/readonly-tmp"
  mkdir -p "$readonly_tmp"
  chmod 500 "$readonly_tmp"
  rc=0
  payload_for s1 "$transcript" | TMPDIR="$readonly_tmp" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
    "$dir/bin/fm-babysitter-capture.sh" || rc=$?
  chmod 700 "$readonly_tmp"
  [ "$rc" -eq 0 ] || fail "a full-disk-style mktemp failure did not exit 0 (got $rc)"
  pass "a full-disk-style temp-file failure (every mktemp refused) still exits 0"
}

test_captures_captain_and_firstmate_text_only
test_excludes_operational_injection_and_synthetic_wrappers
test_incremental_replay_and_dedup
test_new_session_reanchors_cursor
test_crewmate_worktree_is_a_silent_noop
test_never_blocks_on_failure_modes
test_never_blocks_when_temp_writes_fail
