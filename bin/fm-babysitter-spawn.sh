#!/usr/bin/env bash
# fm-babysitter-spawn.sh - launch/relaunch the babysitter judge (docs/babysitter.md).
# Not built on bin/fm-spawn.sh's kind=ship/scout/secondmate machinery (see PR
# description); reuses bin/fm-backend.sh's tmux primitives directly.
# Backend: tmux only. Harness: claude only. Launches with
# FM_SUPERVISION_ACTOR=branch so bin/fm-lease-lib.sh's main-only role
# partition refuses the judge if it ever calls fm-spawn/pr-merge/merge-local.
#
# Usage:
#   fm-babysitter-spawn.sh launch [--model <name>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
mkdir -p "$STATE" "$DATA"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "usage: fm-babysitter-spawn.sh launch [--model <name>]" >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Mirrors bin/fm-spawn.sh's model_flag_for_harness claude case.
model_flag() { # <model>
  local model=$1
  [ -n "$model" ] && [ "$model" != default ] || return 0
  printf -- '--model %s ' "$(shell_quote "$model")"
}

write_brief() { # <path>
  cat > "$1" <<'BRIEF'
# Babysitter judge

You are the babysitter: an independent, persistent observer. You are NOT a
crewmate, NOT a secondmate, and you never touch project code. Your only job is
to notice when firstmate (the captain's primary agent) says it will do
something and then does not, or receives an instruction and never acts on it,
or leaves work idle for a long stretch with no visible progress - and to make
sure the captain finds out, one way or another.

Full contract: docs/babysitter.md in the firstmate repo at the path recorded
in state/babysitter.meta's `home=` field. Read it now, in full, before your
first pass - it is the single owner of your inputs, your judgment criteria,
your escalation ladder, and every tool you are allowed to call. This brief
only gets you there; do not treat it as a substitute.

You never merge, never spawn, never edit the backlog, and never send a
message the captain would see as coming from firstmate itself - your outputs
are a queued wake (bin/fm-wake-lib.sh's fm_wake_append via the findings/
escalation tools docs/babysitter.md names) and, for a repeated unresolved
finding, the tier-2 nudge via bin/fm-babysitter-ntfy.sh. Both are the ONLY
ways you ever speak.

Loop forever: read docs/babysitter.md's "Judge pass" procedure, run one bounded
pass, then wait for the next natural prompt (you will be re-invoked; do not
sleep or poll in a tight loop). Never read the whole ledger or findings store
from the start - always resume from your own durable cursor, exactly as
docs/babysitter.md specifies, so a restart loses no finding and re-judges
nothing already judged.
BRIEF
}

CMD=${1:-}
shift 2>/dev/null || true

case "$CMD" in
  launch)
    MODEL=sonnet
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) MODEL=${2:-sonnet}; shift 2 || usage ;;
        *) usage ;;
      esac
    done

    JUDGE_DIR="$DATA/babysitter"
    mkdir -p "$JUDGE_DIR" || { echo "error: could not create $JUDGE_DIR" >&2; exit 1; }
    BRIEF="$JUDGE_DIR/brief.md"
    write_brief "$BRIEF" || { echo "error: could not write $BRIEF" >&2; exit 1; }

    fm_backend_validate_spawn tmux || exit 1
    fm_backend_source tmux || exit 1

    OLD_META="$STATE/babysitter.meta"
    if [ -f "$OLD_META" ]; then
      OLD_WINDOW=$(fm_meta_get "$OLD_META" window)
      [ -z "$OLD_WINDOW" ] || fm_backend_tmux_kill "$OLD_WINDOW" 2>/dev/null || true
    fi

    SES=$(fm_backend_tmux_container_ensure) || { echo "error: could not resolve the tmux container session" >&2; exit 1; }
    W="fm-babysitter"
    fm_backend_tmux_create_task "$SES" "$W" "$JUDGE_DIR" >/dev/null || { echo "error: could not create the babysitter tmux window" >&2; exit 1; }
    TARGET="$SES:$W"

    MODELFLAG=$(model_flag "$MODEL")
    LAUNCH="FM_SUPERVISION_ACTOR=branch CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions ${MODELFLAG}\"\$(cat $(shell_quote "$BRIEF"))\""
    sleep 0.3
    fm_backend_tmux_send_literal "$TARGET" "$LAUNCH" || { echo "error: could not send the launch command" >&2; exit 1; }
    sleep 0.3
    fm_backend_tmux_send_key "$TARGET" Enter || { echo "error: could not submit the launch command" >&2; exit 1; }

    TMP="$STATE/.babysitter.meta.tmp.$$"
    {
      printf 'kind=babysitter\n'
      printf 'backend=tmux\n'
      printf 'window=%s\n' "$TARGET"
      printf 'model=%s\n' "$MODEL"
      printf 'harness=claude\n'
      printf 'home=%s\n' "$FM_ROOT"
      printf 'spawned=%s\n' "$(date +%s)"
    } > "$TMP" || { rm -f "$TMP"; exit 1; }
    mv -f "$TMP" "$STATE/babysitter.meta" || { rm -f "$TMP"; exit 1; }

    CHECK="$STATE/babysitter.check.sh"
    CHECK_TMP="$CHECK.tmp.$$"
    umask 077
    cat > "$CHECK_TMP" <<CHECKSH
#!/usr/bin/env bash
set -u
FM_ROOT_OVERRIDE=$(shell_quote "$FM_ROOT")
export FM_ROOT_OVERRIDE
STATE=$(shell_quote "$STATE")
CONFIG=$(shell_quote "$CONFIG")
# shellcheck disable=SC1091
. $(shell_quote "$SCRIPT_DIR/fm-babysitter-liveness-lib.sh")
OUT=\$(fm_babysitter_liveness_check)
printf '%s\n' "\$OUT" | grep -F 'could not be revived'
exit 0
CHECKSH
    if ! chmod 700 "$CHECK_TMP" || ! mv -f "$CHECK_TMP" "$CHECK"; then
      rm -f "$CHECK_TMP"
      exit 1
    fi
    "$SCRIPT_DIR/fm-check-register.sh" babysitter >/dev/null 2>&1 || true

    printf 'spawned babysitter window=%s\n' "$TARGET"
    ;;
  *) usage ;;
esac
