#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the per-spawn MCP/native-
# integration scoping facts bin/fm-tool-scope-lib.sh depends on
# (.agents/skills/harness-adapters/references/harness/claude.md owns the
# dated table this test refreshes). This is a harness-dependent check per
# firstmate-coding-guidelines "Harness-dependent checks": the verdict comes
# from what the installed vendor CLI actually does, so it must run against
# the real binary rather than a fake. It spends real API tokens on three short
# non-interactive turns and is opt-in for exactly that reason.
#
# Deliberately does NOT override HOME or CLAUDE_CONFIG_DIR: Claude Code's
# OAuth linkage lives partly in the config JSON under that root (verified: an
# isolated fresh HOME reports "Not logged in" even with a real macOS Keychain
# credential present), so faking it here would only prove the fixture is
# logged out. --mcp-config accepts an inline JSON string, which is enough to
# exercise every fact below without touching the operator's real catalog or
# credentials. fm_tool_scope_prepare's own catalog-reading logic is unit
# tested against a fixture in tests/fm-tool-scope-lib.test.sh, and its wiring
# into fm-spawn.sh's launch template is exercised with a fake claude binary in
# tests/fm-spawn-dispatch-profile.test.sh; this file is the one layer neither
# of those can cover, since only the real CLI can prove the real CLI's
# behavior.
set -u

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

if [ "${FM_TOOL_SCOPE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_TOOL_SCOPE_LIVE_E2E=1 to run the claude tool-scoping live regression"
  exit 0
fi

command -v claude >/dev/null 2>&1 || fail "claude not found"
CLAUDE_VERSION=$(claude --version)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-tool-scope-live-e2e.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

PROMPT='List the exact tool names available to you, comma-separated, nothing else. Do not call any tool.'
EMPTY_CONFIG='{"mcpServers":{}}'
# A real, already-installed stdio MCP server (Claude Code's own), used purely
# to prove the inclusion boundary rather than to exercise its tools.
NAMED_CONFIG='{"mcpServers":{"self-serve":{"command":"claude","args":["mcp","serve"]}}}'

# probe <out-file> <extra claude args...>: runs claude -p in the background
# and kills it after a bounded budget, since this Mac has no GNU `timeout`.
probe() {
  local out=$1
  shift
  (claude -p "$PROMPT" "$@" > "$out" 2>&1) &
  local pid=$!
  ( sleep 60; kill "$pid" 2>/dev/null ) &
  local killer=$!
  wait "$pid" 2>/dev/null
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
}

assert_real_response() {
  local out=$1 label=$2
  case "$out" in
    *Bash*) ;;
    *) fail "$label: did not get a real tool listing (auth or transport problem?), got: $out" ;;
  esac
}

probe "$LAB/default.out" --strict-mcp-config --mcp-config "$EMPTY_CONFIG" --no-chrome
default_out=$(cat "$LAB/default.out")
assert_real_response "$default_out" "conservative default probe"
case "$default_out" in
  *mcp__claude-in-chrome__*) fail "the conservative default scope must exclude claude-in-chrome, saw it in: $default_out" ;;
esac
printf 'ok - Claude %s: --strict-mcp-config with an empty --mcp-config and --no-chrome excludes claude-in-chrome\n' "$CLAUDE_VERSION"

probe "$LAB/chrome.out" --strict-mcp-config --mcp-config "$EMPTY_CONFIG" --chrome
chrome_out=$(cat "$LAB/chrome.out")
assert_real_response "$chrome_out" "--chrome probe"
case "$chrome_out" in
  *mcp__claude-in-chrome__*) ;;
  *) fail "--chrome under --strict-mcp-config must still add claude-in-chrome, got: $chrome_out" ;;
esac
printf 'ok - Claude %s: --chrome composes with --strict-mcp-config, adding claude-in-chrome back\n' "$CLAUDE_VERSION"

probe "$LAB/named.out" --strict-mcp-config --mcp-config "$NAMED_CONFIG" --no-chrome
named_out=$(cat "$LAB/named.out")
assert_real_response "$named_out" "named-server probe"
case "$named_out" in
  *mcp__self-serve__*) ;;
  *) fail "a --mcp-config naming a real server must admit its tools, got: $named_out" ;;
esac
case "$named_out" in
  *mcp__claude-in-chrome__*) fail "a named-server-only config must still exclude claude-in-chrome without --chrome, saw it in: $named_out" ;;
esac
printf 'ok - Claude %s: --strict-mcp-config with a real named server admits exactly that server, chrome still off\n' "$CLAUDE_VERSION"
