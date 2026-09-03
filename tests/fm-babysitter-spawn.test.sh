#!/usr/bin/env bash
# tests/fm-babysitter-spawn.test.sh - behavior tests for bin/fm-babysitter-spawn.sh
# (docs/babysitter.md), the judge's launch mechanics. A fake tmux binary
# records every command instead of running a real terminal multiplexer or
# executing the sent launch command, so these tests can assert on exactly what
# was created and sent without ever invoking a real `claude` process.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

SPAWN="$ROOT/bin/fm-babysitter-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-babysitter-spawn-tests)

# fake_tmux_case <name>: set up a case dir with a fake tmux on PATH that
# records every invocation to $dir/tmux.log and tracks window existence in
# $dir/windows (one "session:window" per line) so has-session/new-window's
# duplicate check and kill-window behave like the real thing.
fake_tmux_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/data" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$SELF_DIR/tmux.log"
WINDOWS="$SELF_DIR/windows"
touch "$WINDOWS"
printf '%s\n' "$*" >> "$LOG"
case "${1:-}" in
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  list-windows)
    # -t ses:window-name existence check used by fm_backend_tmux_create_task's
    # duplicate guard: "tmux list-windows -t $ses -F '#{window_name}'"
    ses=${4:-}
    grep -q "^${ses}:" "$WINDOWS" && sed -n "s/^${ses}://p" "$WINDOWS"
    exit 0
    ;;
  new-window)
    # new-window -dP -F '#{window_id}' -t "SES:" -n NAME -c DIR
    ses_arg=''
    name_arg=''
    prev=''
    for a in "$@"; do
      [ "$prev" = -t ] && ses_arg=$a
      [ "$prev" = -n ] && name_arg=$a
      prev=$a
    done
    ses=${ses_arg%:}
    printf '%s:%s\n' "$ses" "$name_arg" >> "$WINDOWS"
    printf '@1\n'
    exit 0
    ;;
  set-window-option) exit 0 ;;
  kill-window)
    target=${3:-}
    target=${target#=}
    target=${target//=/}
    grep -vF "$target" "$WINDOWS" > "$WINDOWS.tmp" 2>/dev/null || true
    mv -f "$WINDOWS.tmp" "$WINDOWS" 2>/dev/null || true
    exit 0
    ;;
  send-keys) exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  printf '%s' "$dir"
}

test_launch_writes_meta_brief_and_submits() {
  local dir
  dir=$(fake_tmux_case launch)
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    "$SPAWN" launch --model haiku > "$dir/out" 2>&1 || fail "launch failed: $(cat "$dir/out")"

  [ -f "$dir/state/babysitter.meta" ] || fail "no meta was written"
  grep -q '^kind=babysitter$' "$dir/state/babysitter.meta" || fail "meta missing kind=babysitter"
  grep -q '^backend=tmux$' "$dir/state/babysitter.meta" || fail "meta missing backend=tmux"
  grep -q '^model=haiku$' "$dir/state/babysitter.meta" || fail "meta did not record the requested model"
  grep -q '^window=firstmate:fm-babysitter$' "$dir/state/babysitter.meta" || fail "meta window field unexpected: $(cat "$dir/state/babysitter.meta")"

  [ -f "$dir/data/babysitter/brief.md" ] || fail "no brief was written"
  grep -q 'docs/babysitter.md' "$dir/data/babysitter/brief.md" || fail "brief does not point at the owner doc"

  grep -q 'new-window' "$dir/tmux.log" || fail "no tmux window was created"
  SENT=$(grep -F ' -l ' "$dir/tmux.log" | tail -1)
  printf '%s' "$SENT" | grep -qF 'FM_SUPERVISION_ACTOR=branch' \
    || fail "launch command did not set FM_SUPERVISION_ACTOR=branch: $SENT"
  printf '%s' "$SENT" | grep -qF -- '--dangerously-skip-permissions' \
    || fail "launch command did not use the standard unattended-agent flag: $SENT"
  ENTER_COUNT=$(grep -cE '^send-keys -t .* Enter$' "$dir/tmux.log")
  [ "$ENTER_COUNT" -ge 1 ] || fail "the launch command was typed but never submitted with Enter: $(cat "$dir/tmux.log")"
  pass "launch writes meta, writes a brief pointing at the owner doc, and sends+submits the launch command"
}

test_relaunch_kills_the_old_window_first() {
  local dir
  dir=$(fake_tmux_case relaunch)
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    "$SPAWN" launch > "$dir/out1" 2>&1 || fail "first launch failed: $(cat "$dir/out1")"
  FIRST_WINDOW_COUNT=$(wc -l < "$dir/windows")

  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    "$SPAWN" launch > "$dir/out2" 2>&1 || fail "relaunch failed: $(cat "$dir/out2")"

  grep -q 'kill-window' "$dir/tmux.log" || fail "relaunch did not kill the prior window before creating a new one"
  SECOND_WINDOW_COUNT=$(wc -l < "$dir/windows")
  [ "$FIRST_WINDOW_COUNT" -eq 1 ] || fail "unexpected window count after first launch: $FIRST_WINDOW_COUNT"
  [ "$SECOND_WINDOW_COUNT" -eq 1 ] || fail "relaunch left more than one live window recorded: $SECOND_WINDOW_COUNT"
  pass "relaunching kills the previous window before creating a fresh one, never leaving a duplicate"
}

test_launch_defaults_model_to_sonnet() {
  local dir
  dir=$(fake_tmux_case default-model)
  PATH="$dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    "$SPAWN" launch > "$dir/out" 2>&1 || fail "launch failed: $(cat "$dir/out")"
  grep -q '^model=sonnet$' "$dir/state/babysitter.meta" || fail "default model was not sonnet: $(cat "$dir/state/babysitter.meta")"
  pass "an omitted --model defaults to the cheap sonnet model, never opus"
}

test_launch_writes_meta_brief_and_submits
test_relaunch_kills_the_old_window_first
test_launch_defaults_model_to_sonnet
