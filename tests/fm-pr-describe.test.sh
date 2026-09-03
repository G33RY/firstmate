#!/usr/bin/env bash
# Tests for bin/fm-pr-describe.sh: the mechanical half of rewriting a task's
# GitHub pull request description into the captain's human-reviewable format.
#
# Matrix:
#   (a) a first rewrite archives the machine-written body and applies the new one
#   (b) a re-run with an unchanged live body does not duplicate the archive
#   (c) a live body that drifted since the last applied rewrite (a later
#       no-mistakes run overwrote it) is archived again before the new one lands
#   (d) a GitLab URL is refused before either tool is invoked
#   (e) a missing `gh` refuses before `gh-axi` is invoked
#   (f) a missing `gh-axi` refuses before any edit is attempted
#   (g) a failed read refuses without archiving or editing, and the live body
#       is left exactly as it was
#   (h) a failed edit still archives the pre-edit body, but never records the
#       failed rewrite as applied
#   (i) an edit that reports success but does not take (a live body mismatch
#       on verification) is refused, and the mismatched body is never recorded
#       as applied
#   (j) an invalid task id refuses before any tool call
#   (k) a missing body file refuses before any tool call
#   (l) --help succeeds and prints usage
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESCRIBE="$ROOT/bin/fm-pr-describe.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-describe-tests)
BASE_PATH=$PATH
PR_URL="https://github.com/example/repo/pull/9"

# Build a fresh sandbox for one test case: a state dir and a fakebin with gh
# and gh-axi mocks driven by a shared "live body" file, so the mocks behave
# like a real forge round-trip (an edit through gh-axi changes what the next
# gh read returns). Echoes the case dir.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  printf '%s\n' "$case_dir"
}

# write_live_body <case_dir> <text>: seeds the forge's current body.
write_live_body() {
  printf '%s' "$2" > "$1/live-body"
}

add_gh_mocks() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ ! -e "$FM_TEST_GH_VIEW_FAILS" ] || { echo "error: forced view failure" >&2; exit 1; }
    cat "$FM_TEST_LIVE_BODY"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr edit")
    [ ! -e "$FM_TEST_GH_AXI_EDIT_FAILS" ] || { echo "error: forced edit failure" >&2; exit 1; }
    prev=
    for arg in "$@"; do
      if [ "$prev" = "--body-file" ]; then
        cat "$arg" > "$FM_TEST_LIVE_BODY"
      fi
      prev=$arg
    done
    [ ! -e "$FM_TEST_GH_AXI_EDIT_CORRUPTS" ] || printf 'corrupted' >> "$FM_TEST_LIVE_BODY"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh" "$case_dir/fakebin/gh-axi"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search
# path, so the case's own mocks answer for every tool that is not the
# omitted one and the refusal names that tool alone whatever the host
# happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

run_describe() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_LIVE_BODY="$case_dir/live-body" \
  FM_TEST_GH_VIEW_FAILS="$case_dir/gh-view-fails" \
  FM_TEST_GH_AXI_EDIT_FAILS="$case_dir/gh-axi-edit-fails" \
  FM_TEST_GH_AXI_EDIT_CORRUPTS="$case_dir/gh-axi-edit-corrupts" \
  PATH="${FM_TEST_DESCRIBE_PATH:-$case_dir/fakebin:$BASE_PATH}" \
    "$DESCRIBE" "$@"
}

test_first_rewrite_archives_and_applies() {
  local case_dir rc out
  case_dir=$(make_case first-rewrite)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "## Intent
machine-written brief restatement"
  printf '%s' "## Summary
Rewrites the PR body.

## What changed
- bin/fm-pr-describe.sh

## Why
Machine-written bodies are unreviewable.

## Testing
tests/fm-pr-describe.test.sh" > "$case_dir/new-body"

  set +e
  out=$(run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/new-body" 2>"$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "first-rewrite: fm-pr-describe should succeed"
  assert_contains "$out" "described: $PR_URL" "first-rewrite: stdout should confirm the rewritten URL"
  assert_grep "machine-written brief restatement" "$case_dir/state/task-1.pr-original-body" \
    "first-rewrite: the machine-written body must be archived before it is overwritten"
  [ "$(cat "$case_dir/state/task-1.pr-applied-body")" = "$(cat "$case_dir/new-body")" ] \
    || fail "first-rewrite: pr-applied-body must record the exact rewritten body"
  [ "$(cat "$case_dir/live-body")" = "$(cat "$case_dir/new-body")" ] \
    || fail "first-rewrite: the live PR body must equal the rewritten body"
  assert_grep "pr edit" "$case_dir/gh-axi.log" "first-rewrite: gh-axi pr edit must be called"
  assert_grep "9 --repo example/repo" "$case_dir/gh-axi.log" \
    "first-rewrite: gh-axi must be addressed by number and owner/repo parsed from the URL"
  pass "a first rewrite archives the machine-written body and applies the new one"
}

test_unchanged_rerun_does_not_duplicate_archive() {
  local case_dir rc count
  case_dir=$(make_case unchanged-rerun)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "machine body"
  printf '%s' "## Summary
first pass" > "$case_dir/body-1"

  run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body-1" >/dev/null 2>"$case_dir/stderr-1"
  count=$(grep -c '^=== preserved' "$case_dir/state/task-1.pr-original-body")
  [ "$count" = 1 ] || fail "unchanged-rerun: expected exactly one archived entry after the first rewrite, got $count"

  set +e
  run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body-1" >/dev/null 2>"$case_dir/stderr-2"
  rc=$?
  set -e
  expect_code 0 "$rc" "unchanged-rerun: a no-op re-run should still succeed"
  count=$(grep -c '^=== preserved' "$case_dir/state/task-1.pr-original-body")
  [ "$count" = 1 ] \
    || fail "unchanged-rerun: re-applying the same body must not append a second archive entry, got $count"
  pass "a re-run with an unchanged live body does not duplicate the archive"
}

test_drifted_live_body_is_archived_again() {
  local case_dir rc count
  case_dir=$(make_case drifted-rerun)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "original machine body"
  printf '%s' "## Summary
first pass" > "$case_dir/body-1"
  run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body-1" >/dev/null 2>"$case_dir/stderr-1"

  # Simulate a later no-mistakes run clobbering the rewritten body with a
  # fresh machine-written one, in between two firstmate-driven rewrites.
  write_live_body "$case_dir" "second machine-written body from a later pipeline run"
  printf '%s' "## Summary
second pass, before merge" > "$case_dir/body-2"

  set +e
  run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body-2" >/dev/null 2>"$case_dir/stderr-2"
  rc=$?
  set -e
  expect_code 0 "$rc" "drifted-rerun: the second rewrite should succeed"
  count=$(grep -c '^=== preserved' "$case_dir/state/task-1.pr-original-body")
  [ "$count" = 2 ] \
    || fail "drifted-rerun: both the original and the re-run's clobbering body must be archived, got $count entries"
  assert_grep "second machine-written body from a later pipeline run" "$case_dir/state/task-1.pr-original-body" \
    "drifted-rerun: the overwritten pipeline body must survive in the archive too"
  [ "$(cat "$case_dir/state/task-1.pr-applied-body")" = "$(cat "$case_dir/body-2")" ] \
    || fail "drifted-rerun: pr-applied-body must record the latest rewrite"
  pass "a live body that drifted since the last applied rewrite is archived again before the new one lands"
}

test_gitlab_url_refused_before_any_tool_call() {
  local case_dir rc out
  case_dir=$(make_case gitlab-refused)
  add_gh_mocks "$case_dir"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(run_describe "$case_dir" task-1 "https://gitlab.example.com/group/project/-/merge_requests/7" \
    "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-refused: a non-GitHub URL must be refused"
  assert_contains "$out" "GitHub only" "gitlab-refused: the refusal must name the unsupported forge"
  assert_absent "$case_dir/gh.log" "gitlab-refused: gh must never be called"
  assert_absent "$case_dir/gh-axi.log" "gitlab-refused: gh-axi must never be called"
  pass "a GitLab URL is refused before either tool is invoked"
}

test_missing_gh_refuses_before_gh_axi() {
  local case_dir rc out
  case_dir=$(make_case missing-gh)
  add_gh_mocks "$case_dir"
  mirror_path_without "$case_dir/mirror" gh "$case_dir/fakebin"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(FM_TEST_DESCRIBE_PATH="$case_dir/mirror" run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-gh: fm-pr-describe must refuse without gh"
  assert_contains "$out" "requires gh on PATH" "missing-gh: the refusal must name the missing tool"
  assert_absent "$case_dir/gh-axi.log" "missing-gh: gh-axi must never be called once gh is confirmed missing"
  pass "a missing gh refuses before gh-axi is invoked"
}

test_missing_gh_axi_refuses_before_any_edit() {
  local case_dir rc out
  case_dir=$(make_case missing-gh-axi)
  add_gh_mocks "$case_dir"
  mirror_path_without "$case_dir/mirror" gh-axi "$case_dir/fakebin"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(FM_TEST_DESCRIBE_PATH="$case_dir/mirror" run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-gh-axi: fm-pr-describe must refuse without gh-axi"
  assert_contains "$out" "requires gh-axi on PATH" "missing-gh-axi: the refusal must name the missing tool"
  assert_absent "$case_dir/gh.log" "missing-gh-axi: gh must never be called once gh-axi is confirmed missing"
  pass "a missing gh-axi refuses before any edit is attempted"
}

test_failed_read_never_archives_or_edits() {
  local case_dir rc out
  case_dir=$(make_case failed-read)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "untouched machine body"
  : > "$case_dir/gh-view-fails"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "failed-read: a failed read must refuse"
  assert_contains "$out" "could not read the current pull request description" \
    "failed-read: the refusal must name the read failure"
  assert_absent "$case_dir/state/task-1.pr-original-body" "failed-read: nothing should be archived on a failed read"
  assert_absent "$case_dir/gh-axi.log" "failed-read: gh-axi must never be called after a failed read"
  [ "$(cat "$case_dir/live-body")" = "untouched machine body" ] \
    || fail "failed-read: the live PR body must be left exactly as it was"
  pass "a failed read refuses without archiving or editing, and the live body is left exactly as it was"
}

test_failed_edit_archives_but_never_records_applied() {
  local case_dir rc out
  case_dir=$(make_case failed-edit)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "machine body before the failed edit"
  : > "$case_dir/gh-axi-edit-fails"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "failed-edit: a failed edit must refuse"
  assert_contains "$out" "could not apply the rewritten pull request description" \
    "failed-edit: the refusal must name the edit failure"
  assert_grep "machine body before the failed edit" "$case_dir/state/task-1.pr-original-body" \
    "failed-edit: the pre-edit body must still be archived"
  assert_absent "$case_dir/state/task-1.pr-applied-body" \
    "failed-edit: a failed edit must never be recorded as the applied rewrite"
  pass "a failed edit still archives the pre-edit body, but never records the failed rewrite as applied"
}

test_verify_mismatch_is_refused_and_not_recorded() {
  local case_dir rc out
  case_dir=$(make_case verify-mismatch)
  add_gh_mocks "$case_dir"
  write_live_body "$case_dir" "machine body before the corrupted edit"
  : > "$case_dir/gh-axi-edit-corrupts"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "verify-mismatch: an edit that does not take must refuse"
  assert_contains "$out" "did not take" "verify-mismatch: the refusal must say the edit did not take"
  assert_absent "$case_dir/state/task-1.pr-applied-body" \
    "verify-mismatch: a mismatched body must never be recorded as applied"
  pass "an edit that reports success but does not take is refused, and the mismatched body is never recorded as applied"
}

test_invalid_task_id_refuses_before_any_call() {
  local case_dir rc out
  case_dir=$(make_case invalid-id)
  add_gh_mocks "$case_dir"
  printf '%s' "## Summary" > "$case_dir/body"

  set +e
  out=$(run_describe "$case_dir" "../escape" "$PR_URL" "$case_dir/body" 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "invalid-id: an unsafe task id must be refused"
  assert_absent "$case_dir/gh.log" "invalid-id: gh must never be called"
  pass "an invalid task id refuses before any tool call"
}

test_missing_body_file_refuses_before_any_call() {
  local case_dir rc out
  case_dir=$(make_case missing-body)
  add_gh_mocks "$case_dir"

  set +e
  out=$(run_describe "$case_dir" task-1 "$PR_URL" "$case_dir/does-not-exist" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "missing-body: a missing body file must be refused"
  assert_contains "$out" "body file not found" "missing-body: the refusal must name the missing file"
  assert_absent "$case_dir/gh.log" "missing-body: gh must never be called"
  pass "a missing body file refuses before any tool call"
}

test_help_succeeds_and_prints_usage() {
  local out rc
  set +e
  out=$("$DESCRIBE" --help 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$out" "usage: fm-pr-describe.sh" "--help must print usage"
  pass "--help succeeds and prints usage"
}

test_first_rewrite_archives_and_applies
test_unchanged_rerun_does_not_duplicate_archive
test_drifted_live_body_is_archived_again
test_gitlab_url_refused_before_any_tool_call
test_missing_gh_refuses_before_gh_axi
test_missing_gh_axi_refuses_before_any_edit
test_failed_read_never_archives_or_edits
test_failed_edit_archives_but_never_records_applied
test_verify_mismatch_is_refused_and_not_recorded
test_invalid_task_id_refuses_before_any_call
test_missing_body_file_refuses_before_any_call
test_help_succeeds_and_prints_usage
