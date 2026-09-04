#!/usr/bin/env bash
# tests/fm-decision-ledger-page.test.sh - behavior tests for
# bin/fm-decision-ledger-page.sh: proves first publish creates a page and
# records its identity, a later publish updates the same page in place using
# the stored update_key rather than creating a new one, a rejected update is
# reported rather than silently replaced, and `info` reads the stored record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

SCRIPT="$ROOT/bin/fm-decision-ledger-page.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-ledger-page-tests)

new_case() { # <name> -> dir with a data/ home and an HTML fixture
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/data"
  printf '<html><body>ledger</body></html>' > "$dir/page.html"
  printf '%s' "$dir"
}

# Fake HTTP exec: reads scripted "<status>\t<body>" lines from $dir/responses
# (one per call, in order) and records every call's argv+body to $dir/calls.
fake_exec() { # <dir>
  local dir=$1
  cat > "$dir/http.sh" <<'REC'
#!/usr/bin/env bash
dir=$(dirname "$0")
{
  printf 'METHOD=%s URL=%s BEARER=%s\n' "$1" "$2" "$3"
  printf 'BODY='; cat "$4"; printf '\n'
} >> "$dir/calls"
line=$(head -n1 "$dir/responses")
sed -i.bak '1d' "$dir/responses" && rm -f "$dir/responses.bak"
status=${line%%$'\t'*}
body=${line#*$'\t'}
printf '%s\n' "$body"
printf 'HTTP_STATUS:%s\n' "$status"
REC
  chmod +x "$dir/http.sh"
}

run_ledger() { # <dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_DATA_OVERRIDE="$dir/data" \
    FM_DECISION_LEDGER_HTTP_EXEC="$dir/http.sh" "$SCRIPT" "$@"
}

test_first_publish_creates_and_records() {
  local dir out record
  dir=$(new_case create)
  fake_exec "$dir"
  printf '200\t{"site_id":"abc123","update_key":"key1","url":"https://abc123.ht-ml.app/","status":"active","message":null}\n' > "$dir/responses"

  out=$(run_ledger "$dir" publish proj1 "$dir/page.html") || fail "publish failed: $out"
  echo "$out" | grep -qF 'url: https://abc123.ht-ml.app/' || fail "missing url in output: $out"
  echo "$out" | grep -qE '^password: .+' || fail "missing password in output: $out"

  record="$dir/data/decisions/proj1/page.json"
  [ -f "$record" ] || fail "no record written at $record"
  [ "$(jq -r .site_id "$record")" = "abc123" ] || fail "wrong site_id recorded"
  [ "$(jq -r .update_key "$record")" = "key1" ] || fail "wrong update_key recorded"

  grep -q 'METHOD=POST URL=https://api.ht-ml.app/v1/sites BEARER=' "$dir/calls" \
    || fail "first publish did not POST to the create endpoint: $(cat "$dir/calls")"
  pass "first publish creates the page and records its identity"
}

test_second_publish_updates_in_place() {
  local dir out
  dir=$(new_case update)
  fake_exec "$dir"
  printf '200\t{"site_id":"abc123","update_key":"key1","url":"https://abc123.ht-ml.app/","status":"active","message":null}\n' > "$dir/responses"
  run_ledger "$dir" publish proj1 "$dir/page.html" >/dev/null || fail "first publish failed"

  local pw1
  pw1=$(jq -r .password "$dir/data/decisions/proj1/page.json")

  printf '200\t{"site_id":"abc123","update_key":"key1","url":"https://abc123.ht-ml.app/","status":"active","message":null}\n' > "$dir/responses"
  out=$(run_ledger "$dir" publish proj1 "$dir/page.html") || fail "second publish failed: $out"
  echo "$out" | grep -qF 'url: https://abc123.ht-ml.app/' || fail "second publish returned a different url: $out"

  grep -q 'METHOD=PUT URL=https://api.ht-ml.app/v1/sites/abc123 BEARER=key1' "$dir/calls" \
    || fail "second publish did not PUT the stored site with the stored update_key: $(cat "$dir/calls")"
  [ "$(grep -c 'METHOD=POST' "$dir/calls")" -eq 1 ] || fail "second publish created a second page instead of updating"

  local pw2
  pw2=$(jq -r .password "$dir/data/decisions/proj1/page.json")
  [ "$pw1" = "$pw2" ] || fail "password changed across an update, but it is never resent to ht-ml.app"
  pass "a later publish updates the same recorded page instead of creating a new one"
}

test_rejected_update_fails_without_recreating() {
  local dir out rc record_before record_after
  dir=$(new_case rejected)
  fake_exec "$dir"
  printf '200\t{"site_id":"abc123","update_key":"key1","url":"https://abc123.ht-ml.app/","status":"active","message":null}\n' > "$dir/responses"
  run_ledger "$dir" publish proj1 "$dir/page.html" >/dev/null || fail "first publish failed"
  record_before=$(cat "$dir/data/decisions/proj1/page.json")

  printf '401\t{"detail":"Invalid or missing Authorization header"}\n' > "$dir/responses"
  rc=0
  out=$(run_ledger "$dir" publish proj1 "$dir/page.html" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected update was reported as success"
  echo "$out" | grep -qi "no longer accepts updates" || fail "unexpected failure message: $out"
  [ "$(grep -c 'METHOD=POST' "$dir/calls")" -eq 1 ] || fail "a rejected update silently created a replacement page"

  record_after=$(cat "$dir/data/decisions/proj1/page.json")
  [ "$record_before" = "$record_after" ] || fail "the stored record changed despite the rejected update"
  pass "a rejected update fails loudly and leaves the recorded page untouched instead of recreating it"
}

test_info_reads_the_stored_record() {
  local dir out rc
  dir=$(new_case info)
  fake_exec "$dir"
  printf '200\t{"site_id":"abc123","update_key":"key1","url":"https://abc123.ht-ml.app/","status":"active","message":null}\n' > "$dir/responses"
  run_ledger "$dir" publish proj1 "$dir/page.html" >/dev/null || fail "publish failed"

  out=$(run_ledger "$dir" info proj1) || fail "info failed: $out"
  echo "$out" | grep -qF 'url: https://abc123.ht-ml.app/' || fail "info printed the wrong url: $out"

  rc=0
  run_ledger "$dir" info proj2 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "info succeeded for a project with no recorded page"
  pass "info reads the stored url for a published project and fails for one with none"
}

test_publish_rejects_a_path_as_project() {
  local dir rc
  dir=$(new_case pathcheck)
  fake_exec "$dir"
  printf '200\t{}\n' > "$dir/responses"
  rc=0
  run_ledger "$dir" publish "../escape" "$dir/page.html" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a project name containing a path separator was accepted"
  [ ! -f "$dir/calls" ] || fail "an HTTP call was made for a rejected project name"
  pass "a project name containing a path separator is rejected before any request"
}

test_publish_rejects_bare_dotdot_as_project() {
  local dir rc
  dir=$(new_case dotdotcheck)
  fake_exec "$dir"
  printf '200\t{}\n' > "$dir/responses"
  rc=0
  run_ledger "$dir" publish ".." "$dir/page.html" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a bare '..' project name was accepted"
  [ ! -f "$dir/calls" ] || fail "an HTTP call was made for a rejected project name"

  rc=0
  run_ledger "$dir" publish "." "$dir/page.html" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a bare '.' project name was accepted"
  [ ! -f "$dir/calls" ] || fail "an HTTP call was made for a rejected project name"
  pass "a bare '.' or '..' project name is rejected before any request"
}

test_first_publish_creates_and_records
test_second_publish_updates_in_place
test_rejected_update_fails_without_recreating
test_info_reads_the_stored_record
test_publish_rejects_a_path_as_project
test_publish_rejects_bare_dotdot_as_project
