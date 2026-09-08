# shellcheck shell=bash
# Per-spawn MCP server and native-integration scoping for the claude harness.
#
# Every configured MCP server (issue trackers, compression tools, chat
# integrations) and native integration (claude-in-chrome browser control) is
# otherwise inherited unconditionally by a spawned worker, and their tool
# definitions occupy the worker's context before it reads a line of code. This
# library resolves a per-task --tools spec into the launch flags that scope a
# claude worker down to only the servers its task actually needs.
#
# Verified on Claude Code 2.1.265 (.agents/skills/harness-adapters/references/harness/claude.md):
#   --strict-mcp-config --mcp-config <file>  is a closed positive allowlist over
#     registered MCP servers (user/project/local mcpServers, plugin-provided
#     servers): only servers named in <file> connect, everything else configured
#     elsewhere is ignored.
#   --chrome / --no-chrome  independently toggles the claude-in-chrome browser
#     integration; verified to still apply UNDER --strict-mcp-config (i.e. the
#     two axes compose rather than --chrome being silently overridden).
#   Desktop control (the computer-use integration) has no discovered CLI or
#     settings toggle in this version: it is not listed in `claude --help`, not
#     registered in the mcpServers catalog, and (by direct analogy with
#     claude-in-chrome's independent --chrome gating) is not reachable through
#     --strict-mcp-config either. It is therefore NOT covered by this library
#     and remains available regardless of the resolved --tools spec. Extend
#     fm_tool_scope_prepare here if a future Claude Code version exposes one.
#
# Public entry points:
#   fm_tool_scope_claude_config_path
#     Echoes the path to claude's global mcpServers catalog (the source a named
#     token is copied from), or fails when none is found.
#   fm_tool_scope_catalog <config-path>
#     Echoes the registered MCP server names in that catalog, one per line.
#   fm_tool_scope_prepare <spec> <scope-file-path>
#     Validates <spec> (see below), writes <scope-file-path> when the spec
#     needs one, and echoes the flags to splice into the claude launch command
#     (already trailing-space-separated, ready for string concatenation).
#     Returns 1 with a stderr message naming the exact problem on an unknown
#     token or an unresolvable catalog; writes and prints nothing on failure.
#     The catalog is read only when the spec names an actual server, so the
#     common "all"/"none"/"chrome" specs never touch the operator's live MCP
#     config (which can carry credentials) at all.
#
# --tools spec syntax (comma-separated, no internal whitespace):
#   "all"                    no restriction: prints nothing, writes nothing.
#     Must appear alone; "all,chrome" etc. is refused as ambiguous.
#   ""  or  "none"           the conservative default: zero extra MCP servers,
#     browser control off. Prints "--strict-mcp-config --mcp-config <file>
#     --no-chrome ", with <file> holding {"mcpServers":{}}.
#   "chrome"                 adds --chrome instead of --no-chrome to the above.
#   "<name>"                 a key from fm_tool_scope_catalog's output; copies
#     that server's full definition (including its env/credentials) into the
#     generated scope file so the worker can actually connect to it.
#   Any comma-separated combination of "chrome" and catalog names composes.
#   An unrecognized name is refused, listing the known catalog names, so a
#   typo fails loudly instead of silently granting a narrower or wider scope
#   than intended.

fm_tool_scope_claude_config_path() {
  local candidate
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -f "$CLAUDE_CONFIG_DIR/.claude.json" ]; then
    printf '%s\n' "$CLAUDE_CONFIG_DIR/.claude.json"
    return 0
  fi
  candidate="$HOME/.claude.json"
  [ -f "$candidate" ] || return 1
  printf '%s\n' "$candidate"
}

fm_tool_scope_catalog() {
  local config_path=$1
  jq -r '.mcpServers // {} | keys[]' "$config_path" 2>/dev/null
}

fm_tool_scope_prepare() {
  local spec=$1 scope_file=$2
  local -a tokens=() names=()
  local tok want_chrome=0 config_path catalog unknown=() name_found

  case "$spec" in
    all) return 0 ;;
    ''|none) ;;
    *)
      IFS=',' read -r -a tokens <<<"$spec"
      for tok in "${tokens[@]+"${tokens[@]}"}"; do
        [ -n "$tok" ] || continue
        if [ "$tok" = all ]; then
          echo "error: --tools 'all' must be the entire spec, not combined with other tokens (got '$spec')" >&2
          return 1
        fi
      done
      ;;
  esac

  # The catalog (any configured server's credentials included) is read only
  # when a token actually requests a server by name - never for the common
  # "chrome" and conservative-default cases, so those never touch the
  # operator's live MCP config at all.
  config_path=
  catalog=
  for tok in "${tokens[@]+"${tokens[@]}"}"; do
    [ -n "$tok" ] && [ "$tok" != chrome ] || continue
    config_path=$(fm_tool_scope_claude_config_path) || config_path=
    [ -z "$config_path" ] || catalog=$(fm_tool_scope_catalog "$config_path")
    break
  done

  for tok in "${tokens[@]+"${tokens[@]}"}"; do
    [ -n "$tok" ] || continue
    if [ "$tok" = chrome ]; then
      want_chrome=1
      continue
    fi
    name_found=0
    if [ -n "$catalog" ]; then
      while IFS= read -r c; do
        [ "$c" = "$tok" ] || continue
        name_found=1
        break
      done <<<"$catalog"
    fi
    if [ "$name_found" -eq 1 ]; then
      names+=("$tok")
    else
      unknown+=("$tok")
    fi
  done

  if [ "${#unknown[@]}" -gt 0 ]; then
    {
      printf 'error: --tools names an unknown server or token: %s\n' "$(
        IFS=', '; echo "${unknown[*]}"
      )"
      if [ -n "$catalog" ]; then
        printf 'known servers: %s\n' "$(printf '%s' "$catalog" | tr '\n' ',' | sed 's/,$//')"
      else
        printf 'known servers: none found (no %s)\n' "${config_path:-\$HOME/.claude.json}"
      fi
      printf 'reserved tokens: all, chrome, none\n'
    } >&2
    return 1
  fi

  if [ "${#names[@]}" -gt 0 ]; then
    [ -n "$config_path" ] || {
      echo "error: --tools names a server ('${names[0]}') but no claude MCP config was found to copy it from" >&2
      return 1
    }
    jq --argjson names "$(printf '%s\n' "${names[@]}" | jq -R . | jq -s .)" \
      '{mcpServers: ((.mcpServers // {}) | with_entries(select(.key as $k | $names | index($k) != null)))}' \
      "$config_path" > "$scope_file" || {
      echo "error: could not build the scoped MCP config from $config_path" >&2
      return 1
    }
  else
    printf '{"mcpServers":{}}\n' > "$scope_file"
  fi
  chmod 600 "$scope_file" 2>/dev/null || true

  if [ "$want_chrome" -eq 1 ]; then
    printf -- '--strict-mcp-config --mcp-config %s --chrome ' "$(shell_quote "$scope_file")"
  else
    printf -- '--strict-mcp-config --mcp-config %s --no-chrome ' "$(shell_quote "$scope_file")"
  fi
}
