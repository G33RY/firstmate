#!/usr/bin/env bash
# tests/fm-babysitter-ntfy.test.sh - behavior tests for
# bin/fm-babysitter-ntfy.sh (docs/babysitter.md): the tier-2 escalation
# sender. Proves the content restriction is enforced in code (no caller text
# can reach the outbound payload) and exercises the rate limit and the
# disabled-when-unconfigured path.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
. "$SCRIPT_DIR/lib.sh"

NTFY="$ROOT/bin/fm-babysitter-ntfy.sh"
TMP_ROOT=$(fm_test_tmproot fm-babysitter-ntfy-tests)

new_case() { # <name> -> dir with a configured topic and a recorder seam
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  echo "faketopic" > "$dir/config/babysitter-ntfy-topic"
  chmod 600 "$dir/config/babysitter-ntfy-topic"
  cat > "$dir/rec.sh" <<REC
#!/usr/bin/env bash
{ printf 'ARGV1=%s\n' "\${1:-}"; printf 'STDIN='; cat; printf '\n'; } >> "$dir/recorded"
REC
  chmod +x "$dir/rec.sh"
  printf '%s' "$dir"
}

run_notify() { # <dir> [extra args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_BABYSITTER_NTFY_EXEC="$dir/rec.sh" "$NTFY" notify "$@"
}

test_only_fixed_template_reaches_the_payload() {
  local dir
  dir=$(new_case template)
  run_notify "$dir" --reason unmet-commitment --count 3 --oldest-seconds 2700 || fail "notify failed"
  [ -s "$dir/recorded" ] || fail "no notification was sent"
  grep -qF 'Firstmate: 3 commitment(s) unmet, oldest 2700s - check the terminal.' "$dir/recorded" \
    || fail "unexpected payload: $(cat "$dir/recorded")"
  pass "the outbound payload matches the fixed template with only the given counts interpolated"
}

test_free_text_reason_is_rejected_not_forwarded() {
  local dir rc
  dir=$(new_case injection)
  rc=0
  run_notify "$dir" --reason "captain said fix the secret bug in project foo" --count 1 --oldest-seconds 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a free-text reason was accepted instead of refused"
  [ ! -s "$dir/recorded" ] || fail "a free-text reason reached the sender: $(cat "$dir/recorded")"
  pass "an unrecognized reason is refused by the enum check before any send is attempted"
}

test_disabled_without_topic_file() {
  local dir
  dir="$TMP_ROOT/no-topic"
  mkdir -p "$dir/state" "$dir/config"
  cat > "$dir/rec.sh" <<REC
#!/usr/bin/env bash
echo sent >> "$dir/recorded"
REC
  chmod +x "$dir/rec.sh"
  run_notify "$dir" --reason unmet-commitment --count 1 --oldest-seconds 1
  RC=$?
  [ "$RC" -eq 0 ] || fail "an absent topic file should exit 0 silently, got $RC"
  [ ! -e "$dir/recorded" ] || fail "a send happened despite no configured topic"
  pass "tier 2 is silently disabled when config/babysitter-ntfy-topic is absent"
}

test_rate_limit_suppresses_a_second_send() {
  local dir
  dir=$(new_case cooldown)
  run_notify "$dir" --reason parked-checkpoint --count 1 --oldest-seconds 10
  COUNT1=$(grep -c 'ARGV1=' "$dir/recorded")
  run_notify "$dir" --reason parked-checkpoint --count 2 --oldest-seconds 20
  COUNT2=$(grep -c 'ARGV1=' "$dir/recorded")
  [ "$COUNT1" -eq 1 ] || fail "first notify did not send"
  [ "$COUNT2" -eq 1 ] || fail "a second notify inside the cooldown window was not suppressed"
  pass "a second notify within the cooldown window is suppressed"
}

test_rate_limit_is_scoped_per_reason() {
  local dir
  dir=$(new_case cross-reason)
  run_notify "$dir" --reason unmet-commitment --count 1 --oldest-seconds 10
  run_notify "$dir" --reason parked-checkpoint --count 1 --oldest-seconds 10
  run_notify "$dir" --reason judge-down --count 1 --oldest-seconds 10
  COUNT=$(grep -c 'ARGV1=' "$dir/recorded")
  [ "$COUNT" -eq 3 ] || fail "a send for one reason suppressed a send for a different reason: $COUNT sent, expected 3"
  pass "unmet-commitment, parked-checkpoint, and judge-down rate-limit independently"
}

test_topic_file_must_be_private() {
  local dir
  dir=$(new_case perm)
  chmod 644 "$dir/config/babysitter-ntfy-topic"
  run_notify "$dir" --reason unmet-commitment --count 1 --oldest-seconds 1
  [ ! -e "$dir/recorded" ] || fail "a world-readable topic file was still used"
  pass "a topic file that is not private (mode 600/400) is refused"
}

test_only_fixed_template_reaches_the_payload
test_free_text_reason_is_rejected_not_forwarded
test_disabled_without_topic_file
test_rate_limit_suppresses_a_second_send
test_rate_limit_is_scoped_per_reason
test_topic_file_must_be_private
