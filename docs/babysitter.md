# Babysitter

The babysitter catches firstmate telling the captain it will do something and then not doing it: a stated commitment that never turns into action, a captain instruction firstmate never acknowledged or acted on, or work that is nominally under way but shows no visible progress for a long stretch. It is a third, independent observer beside the turn-end guard (which only checks "is a supervision cycle armed") and the watcher (which only watches crew liveness) - neither of those looks at whether firstmate's own stated intentions become actions.

It has three parts: a deterministic capture hook that records the dialog, a persistent judge agent that reads it and decides, and a two-tier escalation ladder. A fourth, fully deterministic path (PARKED AT CHECKPOINT, below) needs no judge at all.

Capture and PARKED AT CHECKPOINT run unconditionally in a genuine primary checkout. The judge itself is opt-in: create `config/babysitter-enabled` once (see [`configuration.md`](configuration.md)) to have session start spawn and thereafter maintain it; without that file the judge never spawns and its liveness layer is a true no-op.

## Capture

`bin/fm-babysitter-capture.sh` is a third tracked Claude `Stop` hook (`.claude/settings.json`), registered alongside `bin/fm-turnend-guard.sh` and `bin/fm-claude-stop-autoarm.sh`. On every turn end of a genuine firstmate primary session (`fm_primary_scope_matches`, the same predicate the turn-end guard uses - a crewmate/scout worktree, including one spawned on firstmate itself, is a silent no-op), it reads the session's transcript JSONL forward from a durable byte cursor (`state/.babysitter-transcript-cursor`) and appends the captain's plain-text messages and firstmate's plain-text replies to the ledger. It never captures tool calls, tool results, thinking blocks, sidechain (sub-agent) messages, operational injections (`bin/fm-operational-input.sh`), or the CLI's own synthetic wrapper turns (local slash commands, `!`-run bash echoes, interrupt notices).

It is designed to never be the hook that wedges a session: no `set -e`, a non-blocking lock try (a concurrent Stop event skips rather than waits), and every internal failure (malformed payload, missing/unreadable transcript, a torn cursor, a full disk) degrades to silence plus a best-effort marker at `state/.babysitter-capture-error`, never a nonzero exit.

## Ledger

`bin/fm-babysitter-ledger.sh` owns the dialog store: `state/babysitter-ledger.jsonl`, one `{"seq","epoch","role","text"}` per line, `role` is `captain` or `firstmate`. `seq` comes from a persistent counter so it survives rotation (the file is size-bounded, oldest lines dropped via `tail`+`mv` past `FM_BABYSITTER_LEDGER_MAX` lines). Subcommands: `append`, `unread`, `mark-read --through <seq>`, `list`.

## Judge

The judge is a persistent agent with its own tmux window, launched and kept alive by `bin/fm-babysitter-spawn.sh` and `bin/fm-babysitter-liveness-lib.sh` (below) - never a crewmate, never a secondmate. It never touches project code, never spawns, never merges, never edits the backlog, and its launched session runs with `FM_SUPERVISION_ACTOR=branch` so `bin/fm-lease-lib.sh`'s existing main-only role partition refuses it outright if it ever calls `fm-spawn.sh`, `fm-pr-merge.sh`, or `fm-merge-local.sh`.

### Judge pass

Each pass:

1. Read only ledger entries newer than your own cursor: `bin/fm-babysitter-ledger.sh unread`. Never the whole ledger.
2. Read the deterministic fleet snapshot: `bin/fm-fleet-snapshot.sh --json`, and `bin/fm-crew-state.sh <task-id>` for any task whose current state matters (a declared `paused:` is a deliberate external wait, not a stall - never flag it).
3. Judge, at the widest sensitivity the captain chose:
   - **Unmet commitment**: firstmate said in chat it would do something and durable state (ledger, fleet snapshot, crew state) shows no evidence it did.
   - **Unacknowledged instruction**: the captain gave an instruction firstmate never acknowledged or acted on at all.
   - **Stall**: work nominally under way has produced no visible progress for longer than the configured stall threshold (`config/babysitter-stall-minutes`, default 60) - distinguish this from a healthy long-running validation run via `bin/fm-crew-state.sh`.
4. For each finding, append it to the durable store: `bin/fm-babysitter-findings.sh append --kind <unmet-commitment|unacknowledged-instruction|stall> --summary <text> --tier <1|2> --ledger-through <seq>`. Write the finding BEFORE acting on it (store-first durability - a restart between the write and the act just repeats the act, never loses the finding).
5. Act:
   - **Tier 1** (first occurrence): enqueue a durable wake naming the unmet commitment - what firstmate said, when, and what durable state shows instead - via `bin/fm-wake-lib.sh`'s `fm_wake_append check "babysitter:<finding-seq>" "check: <message>"`.
   - **Tier 2** (the same commitment survives repeated tier-1 pokes): `bin/fm-babysitter-ntfy.sh notify --reason unmet-commitment --count <n> --oldest-seconds <s>`. The message is a fixed, content-restricted template built entirely by that script from plain counts - never construct or pass free text, task names, project names, or PR URLs to it.
6. Advance your ledger cursor only after every finding for this pass has been durably stored and acted on: `bin/fm-babysitter-ledger.sh mark-read --through <seq>`.

Never read your own findings store from the start either; if you need to check what you already raised (to decide tier 1 vs tier 2 for the same condition), use `bin/fm-babysitter-findings.sh list --recent <n>` or `unread`, bounded.

### Findings store

`bin/fm-babysitter-findings.sh` owns `state/babysitter-findings.jsonl` (append-only, gap-free, `{"seq","epoch","kind","summary","tier","ledger_through"}`) and `state/.babysitter-findings-cursor`. Same shape as `bin/fm-branch-outcome.sh`. This, plus the ledger cursor above, is what makes the judge killable and restartable at any point without losing a finding or re-judging an already-judged entry.

## PARKED AT CHECKPOINT (deterministic, no judge)

`bin/fm-wake-drain.sh`'s `PARKED AT CHECKPOINT` section and `bin/fm-classify-lib.sh`'s `status_is_parked_checkpoint` detect a `mode=no-mistakes` ship task whose latest status line is a bare `done:` (no PR URL) - the deliberate handoff point where the worker has committed and is waiting for firstmate to trigger `/no-mistakes` (`AGENTS.md` section 7). This is not a worker malfunction; it is firstmate's own unmet obligation, and it needs no LLM judgment to detect. It queues its own `check:` wake (idempotent per task) and, past `FM_BABYSITTER_PARKED_TIER2_SECS` (default 1800s), fires the tier-2 nudge directly through `bin/fm-babysitter-ntfy.sh`.

## Escalation content restriction

`bin/fm-babysitter-ntfy.sh` is the single tier-2 sender, used by both the judge and the deterministic parked-checkpoint path. It reads the ntfy topic fresh from `config/babysitter-ntfy-topic` (absent = tier 2 disabled), rate-limits to one send per `FM_BABYSITTER_NTFY_COOLDOWN_SECS` (default 1800s), and only ever sends one of three fixed templates with a plain count and a plain age in seconds interpolated - no chat content, project name, task id, PR URL, or file path can reach the payload, because the CLI has no parameter that accepts one.

## Liveness and persistence guarantees

What survives, and what does not, across a session end, a context clear, a reboot, or a terminal-server death:

- **Survives everything, including a reboot**: the ledger, its cursor, the findings store, its cursor, and all babysitter config - all plain files on disk.
- **Survives a session end or context clear, not a reboot or terminal-server death**: the judge's own running process (its tmux window).
- **Guaranteed to come back on its own once enabled**, without any agent noticing: judge liveness is a deterministic bash-level guarantee, never the judge's own responsibility. It is opt-in per home (`config/babysitter-enabled`, see [`configuration.md`](configuration.md)); without that flag the whole liveness layer is a true no-op. `bin/fm-bootstrap.sh` calls `fm_babysitter_liveness_check` (`bin/fm-babysitter-liveness-lib.sh`) once per session start, and a registered `state/babysitter.check.sh` gives the watcher the same check on its own poll cadence, so a judge that dies mid-session is noticed and relaunched without waiting for the next session start. `fm_backend_agent_state` classifies the judge's window as `alive` / `dead` / `missing` / `ambiguous` / `unreadable` / `unverified`; only `dead`/`missing` trigger a relaunch, everything else is preserved and reported. After `FM_BABYSITTER_LIVENESS_MAX_ATTEMPTS` (default 3) consecutive failed relaunches the judge is irrevivable: this fires the tier-2 nudge directly (`--reason judge-down`) and reports it loudly at the next session-start digest - silent death is the one outcome this feature cannot have.

Restarting the judge itself is always safe: its brief and cursors are all on disk, so a fresh process resumes exactly where the last one left off.

## Configuration

See [`configuration.md`](configuration.md) "Babysitter" for `config/babysitter-ntfy-topic` and the tunable thresholds.
