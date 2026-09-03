#!/usr/bin/env bash
# Rewrite a task's GitHub pull request description into the captain's
# human-reviewable format, replacing whatever no-mistakes' validation
# pipeline wrote. no-mistakes exposes no PR-body instruction hook (only
# pr.base_branch in .no-mistakes.yaml), so firstmate rewrites the body
# afterwards instead of forking or configuring the pipeline.
#
# This script is the mechanical half only: it fetches the live body, archives
# it, applies the caller-supplied replacement, and verifies the edit took. It
# never composes prose - the caller (firstmate, reading the diff, the task's
# intent, and what validation found) writes the new body to a file and passes
# that file's path. Editing a PR description through the forge is a forge
# operation, like merging; this never touches the task's worktree or project
# files.
#
# The rewritten body follows this exact format, in this order - the single
# owner of the format, so nowhere else restates it:
#   ## Summary       one or two sentences: what this PR does and the risk.
#   ## What changed  bullet list of the concrete changes, file-scoped where useful.
#   ## Why           the motivating problem or decision.
#   ## Testing       what was run or verified.
#   ## Notes         condensed carryover: any finding, deviation, or explicit
#                     deferral from the machine-written body that a reviewer
#                     still needs. Omit the section when nothing survives.
# Scannable in fifteen seconds: lead with what changed and where the risk is.
# Never restate the task's brief or instructions, never a wall of text.
#
# Idempotent and re-run-safe. Every call fetches the PR's current live body
# and compares it (trailing-newline-insensitive) against the body this script
# itself applied last time, recorded at state/<id>.pr-applied-body. Whenever
# they differ - the first call ever, or a later no-mistakes run overwrote the
# rewritten body with a fresh machine-written one - the live body is archived
# unmodified to state/<id>.pr-original-body (append-only, one timestamped
# entry per distinct body ever overwritten) before the new body is applied.
# That sidecar, not the forge, is the recoverable copy: it survives
# independently of PR edit history, is scoped to the task like every other
# private state/<id>.* record, and is cleaned up by teardown with the rest of
# the task's state.
#
# GitHub only. Reads (fetching the live body, verifying the edit took) use
# `gh --json`, matching bin/fm-pr-check.sh's own precedent of reading
# structured PR fields through `gh` rather than parsing gh-axi's reformatted
# text - unsafe for a field whose exact bytes must round-trip. The edit
# itself goes through `gh-axi pr edit --body-file`, matching the exit-code-only
# calls the sibling PR scripts already make. Both are required on PATH.
# A non-GitHub URL, or either tool missing or failing at any step, is
# reported and exits non-zero without changing the PR. This is a cosmetic
# step: a caller must report the failure and continue to its normal outcome
# regardless, never block or reverse delivery on it.
#
# Usage: fm-pr-describe.sh <task-id> <pr-url> <body-file>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  echo "usage: fm-pr-describe.sh <task-id> <pr-url> <body-file>" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi
ID=$1
RAW_URL=$2
BODY_FILE=$3

if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR description request" >&2
  exit 2
fi
URL=$FM_PR_URL
if [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: PR description rewrite supports GitHub only, got provider '$FM_PR_PROVIDER'" >&2
  exit 1
fi
if [ ! -f "$BODY_FILE" ]; then
  echo "error: body file not found: $BODY_FILE" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "error: rewriting a pull request description requires gh on PATH" >&2
  exit 1
fi
if ! command -v gh-axi >/dev/null 2>&1; then
  echo "error: rewriting a pull request description requires gh-axi on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

ORIGINAL="$STATE/$ID.pr-original-body"
APPLIED="$STATE/$ID.pr-applied-body"
LOCK="$STATE/.$ID.pr-describe.lock"

LOCK_HELD=0
LIVE=
ERR=
TMP=
describe_cleanup() {
  [ -z "$LIVE" ] || rm -f -- "$LIVE"
  [ -z "$ERR" ] || rm -f -- "$ERR"
  [ -z "$TMP" ] || rm -f -- "$TMP"
  if [ "$LOCK_HELD" = 1 ]; then
    fm_lock_release "$LOCK" || true
    LOCK_HELD=0
  fi
}
trap describe_cleanup EXIT
trap 'exit 1' HUP INT TERM

LIVE=$(mktemp "$STATE/.fm-pr-describe-live.XXXXXX") || exit 1
ERR=$(mktemp "$STATE/.fm-pr-describe-err.XXXXXX") || exit 1

if ! gh pr view "$URL" --json body -q .body > "$LIVE" 2> "$ERR"; then
  echo "error: could not read the current pull request description: $(cat "$ERR")" >&2
  exit 1
fi

fm_lock_acquire_wait "$LOCK"
LOCK_HELD=1

if [ ! -f "$APPLIED" ] || [ "$(cat "$APPLIED")" != "$(cat "$LIVE")" ]; then
  TMP=$(mktemp "$STATE/.fm-pr-describe-archive.XXXXXX") || exit 1
  [ ! -f "$ORIGINAL" ] || cat "$ORIGINAL" > "$TMP"
  {
    printf '=== preserved %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat "$LIVE"
    printf '\n'
  } >> "$TMP"
  chmod 0600 "$TMP"
  mv -f -- "$TMP" "$ORIGINAL"
  TMP=
fi

if ! EDIT_OUT=$(gh-axi pr edit "$FM_PR_NUMBER" --repo "$FM_PR_OWNER/$FM_PR_REPO" --body-file "$BODY_FILE" 2>&1); then
  [ -z "$EDIT_OUT" ] || printf '%s\n' "$EDIT_OUT" >&2
  echo "error: could not apply the rewritten pull request description" >&2
  exit 1
fi

: > "$LIVE"
if ! gh pr view "$URL" --json body -q .body > "$LIVE" 2> "$ERR"; then
  echo "error: pull request description was edited but could not be verified: $(cat "$ERR")" >&2
  exit 1
fi
if [ "$(cat "$BODY_FILE")" != "$(cat "$LIVE")" ]; then
  echo "error: pull request description edit did not take; live body does not match the requested rewrite" >&2
  exit 1
fi

TMP=$(mktemp "$STATE/.fm-pr-describe-applied.XXXXXX") || exit 1
cat "$BODY_FILE" > "$TMP"
chmod 0600 "$TMP"
mv -f -- "$TMP" "$APPLIED"
TMP=

fm_lock_release "$LOCK"
LOCK_HELD=0

printf 'described: %s\n' "$URL"
