#!/usr/bin/env bash
# tests/fm-tool-scope-lib.test.sh - unit tests for the per-spawn MCP/native-
# integration scoping library (bin/fm-tool-scope-lib.sh) plus structural checks
# that bin/fm-spawn.sh wires --tools into the claude launch template. Pure
# functions and a fake catalog file, no real claude binary and no live spawn
# required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# fm_tool_scope_prepare shell_quote's the generated scope file path; mirror
# fm-spawn.sh's own definition rather than sourcing the whole 3000+ line
# script for one helper.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tool-scope-lib.sh"

command -v jq >/dev/null 2>&1 || fail "jq is required by fm-tool-scope-lib.sh and this test"

LAB=$(fm_test_tmproot fm-tool-scope)
HOME_DIR="$LAB/home"
mkdir -p "$HOME_DIR"
cat > "$HOME_DIR/.claude.json" <<'JSON'
{
  "mcpServers": {
    "atlassian-test": {
      "command": "uvx",
      "args": ["mcp-atlassian"],
      "env": { "JIRA_API_TOKEN": "secret-token-should-not-leak" }
    },
    "gmail-test": {
      "command": "uv",
      "args": ["run", "gmail-server.py"]
    }
  }
}
JSON

# --- config path resolution --------------------------------------------------

(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  path=$(fm_tool_scope_claude_config_path) || exit 1
  [ "$path" = "$HOME_DIR/.claude.json" ] || exit 1
) || fail "fm_tool_scope_claude_config_path must resolve \$HOME/.claude.json"
pass "fm_tool_scope_claude_config_path resolves \$HOME/.claude.json"

ALT_DIR="$LAB/alt-config-dir"
mkdir -p "$ALT_DIR"
printf '{"mcpServers":{"alt-only":{"command":"true","args":[]}}}\n' > "$ALT_DIR/.claude.json"
(
  HOME=$HOME_DIR
  CLAUDE_CONFIG_DIR=$ALT_DIR
  export CLAUDE_CONFIG_DIR
  path=$(fm_tool_scope_claude_config_path) || exit 1
  [ "$path" = "$ALT_DIR/.claude.json" ] || exit 1
) || fail "CLAUDE_CONFIG_DIR must take precedence over \$HOME/.claude.json when its .claude.json exists"
pass "fm_tool_scope_claude_config_path prefers an existing \$CLAUDE_CONFIG_DIR/.claude.json"

(
  HOME="$LAB/no-config-here"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_claude_config_path >/dev/null 2>&1 && exit 1
  exit 0
) || fail "fm_tool_scope_claude_config_path must fail when no .claude.json exists"
pass "fm_tool_scope_claude_config_path fails closed with no catalog file"

# --- catalog listing ----------------------------------------------------------

catalog=$(fm_tool_scope_catalog "$HOME_DIR/.claude.json" | sort)
[ "$catalog" = "$(printf 'atlassian-test\ngmail-test\n' | sort)" ] \
  || fail "fm_tool_scope_catalog must list exactly the configured server names, got: $catalog"
pass "fm_tool_scope_catalog lists the registered server names"

# --- spec resolution: all ----------------------------------------------------

SCOPE_FILE="$LAB/scope-all.json"
(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare all "$SCOPE_FILE"
) > "$LAB/flags-all.txt" || fail "fm_tool_scope_prepare all must succeed"
[ -s "$LAB/flags-all.txt" ] && fail "fm_tool_scope_prepare all must print no launch flags, got: $(cat "$LAB/flags-all.txt")"
[ ! -e "$SCOPE_FILE" ] || fail "fm_tool_scope_prepare all must not write a scope file"
pass "fm_tool_scope_prepare all is a true no-op: no flags, no scope file"

# --- spec resolution: conservative default (empty and 'none' are equivalent) -

for spec in '' none; do
  SCOPE_FILE="$LAB/scope-default-${spec:-empty}.json"
  flags=$(
    HOME=$HOME_DIR
    unset CLAUDE_CONFIG_DIR
    fm_tool_scope_prepare "$spec" "$SCOPE_FILE"
  ) || fail "fm_tool_scope_prepare '$spec' must succeed"
  case "$flags" in
    *--strict-mcp-config*"$SCOPE_FILE"*--no-chrome*) ;;
    *) fail "conservative spec '$spec' must emit --strict-mcp-config --mcp-config <file> --no-chrome, got: $flags" ;;
  esac
  [ "$(jq -c '.mcpServers' "$SCOPE_FILE")" = '{}' ] \
    || fail "conservative spec '$spec' must write an empty mcpServers object"
done
pass "empty spec and 'none' both resolve to zero servers and --no-chrome"

# --- spec resolution: chrome only --------------------------------------------

SCOPE_FILE="$LAB/scope-chrome.json"
flags=$(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare chrome "$SCOPE_FILE"
) || fail "fm_tool_scope_prepare chrome must succeed"
case "$flags" in
  *--chrome*) ;;
  *) fail "'chrome' spec must emit --chrome, got: $flags" ;;
esac
case "$flags" in
  *--no-chrome*) fail "'chrome' spec must not also emit --no-chrome, got: $flags" ;;
esac
[ "$(jq -c '.mcpServers' "$SCOPE_FILE")" = '{}' ] || fail "'chrome' alone must still write zero servers"
pass "'chrome' spec emits --chrome and grants no MCP servers"

# --- spec resolution: named server, secret preserved for the worker ----------

SCOPE_FILE="$LAB/scope-named.json"
flags=$(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare atlassian-test "$SCOPE_FILE"
) || fail "fm_tool_scope_prepare atlassian-test must succeed"
case "$flags" in *--no-chrome*) ;; *) fail "a named-server-only spec must still default browser control off, got: $flags" ;; esac
[ "$(jq -r '.mcpServers | keys | length' "$SCOPE_FILE")" = 1 ] \
  || fail "exactly one server must be copied into the scope file"
[ "$(jq -r '.mcpServers | has("atlassian-test")' "$SCOPE_FILE")" = true ] \
  || fail "the requested server must be present in the scope file"
[ "$(jq -r '.mcpServers | has("gmail-test")' "$SCOPE_FILE")" = false ] \
  || fail "an unrequested server must not leak into the scope file"
[ "$(jq -r '.mcpServers["atlassian-test"].env.JIRA_API_TOKEN' "$SCOPE_FILE")" = "secret-token-should-not-leak" ] \
  || fail "the granted server's own credentials must be preserved so the worker can actually connect"
pass "a named server is copied into the scope file with its credentials, and nothing else leaks in"

perm=$(stat -f '%Lp' "$SCOPE_FILE" 2>/dev/null || stat -c '%a' "$SCOPE_FILE" 2>/dev/null)
[ "$perm" = 600 ] || fail "the scope file (it can carry live credentials) must be mode 600, got $perm"
pass "the generated scope file is written mode 600"

# --- spec resolution: combining a name with chrome ---------------------------

SCOPE_FILE="$LAB/scope-combo.json"
flags=$(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare gmail-test,chrome "$SCOPE_FILE"
) || fail "fm_tool_scope_prepare gmail-test,chrome must succeed"
case "$flags" in *--chrome*) ;; *) fail "combined spec must still emit --chrome, got: $flags" ;; esac
[ "$(jq -r '.mcpServers | has("gmail-test")' "$SCOPE_FILE")" = true ] \
  || fail "combined spec must still grant the named server"
pass "a server name and 'chrome' compose in one spec"

# --- refusals: unknown token and ambiguous 'all' ------------------------------

(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare not-a-real-server "$LAB/scope-bad.json"
) > "$LAB/out-unknown.txt" 2>"$LAB/err-unknown.txt"
rc=$?
[ "$rc" -ne 0 ] || fail "an unknown server name must be refused, not silently dropped or silently granted"
[ ! -e "$LAB/scope-bad.json" ] || fail "a refused spec must not write a partial scope file"
grep -q "not-a-real-server" "$LAB/err-unknown.txt" || fail "the refusal must name the exact unknown token"
grep -q "atlassian-test" "$LAB/err-unknown.txt" || fail "the refusal must list the known servers so the caller can self-correct"
pass "an unknown server name is refused loudly, naming the token and the known catalog"

(
  HOME=$HOME_DIR
  unset CLAUDE_CONFIG_DIR
  fm_tool_scope_prepare all,chrome "$LAB/scope-ambiguous.json"
) >/dev/null 2>"$LAB/err-ambiguous.txt"
rc=$?
[ "$rc" -ne 0 ] || fail "'all' combined with another token must be refused as ambiguous"
[ ! -e "$LAB/scope-ambiguous.json" ] || fail "a refused ambiguous spec must not write a scope file"
pass "'all' combined with another token is refused rather than silently picking one meaning"

# --- structural: fm-spawn.sh wiring ------------------------------------------

grep -q -- '--tools) want_value=tools' "$ROOT/bin/fm-spawn.sh" \
  || fail "fm-spawn.sh must accept --tools on the command line"
grep -q '__TOOLSFLAG__' "$ROOT/bin/fm-spawn.sh" \
  || fail "fm-spawn.sh's claude launch template must carry the __TOOLSFLAG__ placeholder"
# shellcheck disable=SC2016
grep -q 'fm_tool_scope_prepare "\$TOOLS_EFFECTIVE"' "$ROOT/bin/fm-spawn.sh" \
  || fail "fm-spawn.sh must resolve the launch flags through fm_tool_scope_prepare"
# shellcheck disable=SC2016
grep -q 'echo "tools=\$TOOLS_EFFECTIVE"' "$ROOT/bin/fm-spawn.sh" \
  || fail "fm-spawn.sh must record the effective --tools spec in task meta for traceability"
pass "fm-spawn.sh wires --tools through fm_tool_scope_prepare into the claude launch template and task meta"
